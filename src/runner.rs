use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::claude_hook;
use crate::codex_exec;
use crate::model::{AgentFamily, SessionSnapshot, unix_millis};
use crate::pi_rpc;
use crate::process::{ProcessObservation, query_process};
use crate::runtime::{LaunchRecord, RuntimeMonitor};

const CLAUDE_HOOK_SCRIPT: &str = include_str!("../scripts/claude-observer-hook.ps1");
const POLL_INTERVAL: Duration = Duration::from_millis(250);
static BINDING_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunFamily {
    Claude,
    Codex,
    Pi,
}

impl RunFamily {
    pub fn agent_family(self) -> AgentFamily {
        match self {
            Self::Claude => AgentFamily::Claude,
            Self::Codex => AgentFamily::Codex,
            Self::Pi => AgentFamily::Pi,
        }
    }
}

pub struct RunOptions {
    pub family: RunFamily,
    pub cwd: PathBuf,
    pub executable: PathBuf,
    pub child_args: Vec<String>,
    pub runtime_binding_root: PathBuf,
    pub claude_hook_root: PathBuf,
    pub pi: Option<Box<PiRunOptions>>,
}

pub struct PiRunOptions {
    pub node_executable: PathBuf,
    pub pi_cli_js: PathBuf,
    pub session_dir: PathBuf,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub thinking: Option<String>,
    pub name: String,
    pub prompt: String,
}

pub struct RunOutcome {
    pub status: ExitStatus,
    pub runtime_binding_id: String,
    pub final_snapshot: Option<SessionSnapshot>,
}

pub fn run(options: RunOptions) -> Result<RunOutcome, String> {
    if options.family == RunFamily::Pi {
        let pi = options
            .pi
            .as_ref()
            .ok_or_else(|| "run pi requires Pi-specific options".to_string())?;
        return run_pi(pi, &options);
    }
    run_cli(options)
}

fn run_cli(options: RunOptions) -> Result<RunOutcome, String> {
    if !options.cwd.is_dir() {
        return Err(format!("run cwd does not exist: {}", options.cwd.display()));
    }
    fs::create_dir_all(&options.runtime_binding_root).map_err(|error| {
        format!(
            "cannot create runtime binding root {}: {error}",
            options.runtime_binding_root.display()
        )
    })?;
    let binding_id = new_binding_id();
    let launched_at = SystemTime::now();
    let source_root = match options.family {
        RunFamily::Claude => {
            fs::create_dir_all(&options.claude_hook_root).map_err(|error| {
                format!(
                    "cannot create Claude hook root {}: {error}",
                    options.claude_hook_root.display()
                )
            })?;
            options.claude_hook_root.clone()
        }
        RunFamily::Codex => {
            let root = options.runtime_binding_root.join("codex-exec");
            fs::create_dir_all(&root).map_err(|error| {
                format!("cannot create Codex event root {}: {error}", root.display())
            })?;
            root
        }
        RunFamily::Pi => unreachable!("run pi is dispatched to run_pi before run_cli"),
    };

    let mut command = Command::new(&options.executable);
    command.current_dir(&options.cwd).stderr(Stdio::inherit());
    let reader = match options.family {
        RunFamily::Claude => {
            if options
                .child_args
                .iter()
                .any(|argument| argument == "--settings" || argument.starts_with("--settings="))
            {
                return Err(
                    "run claude manages --settings; remove the child --settings argument"
                        .to_string(),
                );
            }
            let settings = write_claude_support(&options.runtime_binding_root, &binding_id)?;
            command
                .arg("--settings")
                .arg(settings)
                .args(&options.child_args)
                .env("AGENT_OBSERVER_CLAUDE_HOOK_ROOT", &options.claude_hook_root)
                .stdout(Stdio::inherit());
            None
        }
        RunFamily::Codex => {
            let args = options
                .child_args
                .strip_prefix(&["exec".to_string()])
                .unwrap_or(&options.child_args);
            command
                .args(["exec", "--json", "--ephemeral", "--skip-git-repo-check"])
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::piped());
            Some(source_root.join(format!("{binding_id}.jsonl")))
        }
        RunFamily::Pi => unreachable!("run pi is dispatched to run_pi before run_cli"),
    };

    let mut child = command
        .spawn()
        .map_err(|error| format!("cannot start {}: {error}", options.executable.display()))?;
    let process_id = child.id();
    let process_started_at = match wait_for_process_start(process_id) {
        Ok(started_at) => started_at,
        Err(message) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(message);
        }
    };
    let record_path = options
        .runtime_binding_root
        .join(format!("{binding_id}.json"));
    let launch_record = LaunchRecord::new(
        record_path,
        binding_id.clone(),
        options.family.agent_family(),
        process_id,
        process_started_at,
        Some(options.cwd.to_string_lossy().into_owned()),
        launched_at,
        match options.family {
            RunFamily::Claude => "claude-hook",
            RunFamily::Codex => "codex-exec-json",
            RunFamily::Pi => unreachable!("run pi is dispatched to run_pi before run_cli"),
        },
    );
    if let Err(message) = launch_record.persist() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!(
            "cannot persist exact runtime binding; launched process was stopped: {message}"
        ));
    }

    let reader_thread = if let Some(event_path) = reader {
        let Some(stdout) = child.stdout.take() else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(
                "Codex stdout pipe was not created; launched process was stopped".to_string(),
            );
        };
        let binding_id = binding_id.clone();
        let cwd = options.cwd.clone();
        Some(thread::spawn(move || {
            stream_codex_stdout(stdout, &event_path, &binding_id, &cwd)
        }))
    } else {
        None
    };

    let observer_instance_id = format!("observe-run-{}-{}", process_id, unix_millis(launched_at));
    let mut monitor = RuntimeMonitor::load(&options.runtime_binding_root, observer_instance_id);
    let mut final_snapshot = None;
    loop {
        if let Some(mut snapshot) =
            owned_snapshot(options.family, &source_root, &binding_id, SystemTime::now())
        {
            monitor.refresh_from_disk(&options.runtime_binding_root);
            monitor.apply(
                std::slice::from_mut(&mut snapshot),
                SystemTime::now(),
                crate::runtime::observe_windows_process,
            );
            final_snapshot = Some(snapshot);
        }
        let child_status = match child.try_wait() {
            Ok(status) => status,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "cannot query launched CLI status; launched process was stopped: {error}"
                ));
            }
        };
        if let Some(status) = child_status {
            if let Some(reader_thread) = reader_thread {
                reader_thread
                    .join()
                    .map_err(|_| "Codex stdout reader panicked".to_string())??;
            }
            thread::sleep(POLL_INTERVAL);
            if let Some(mut snapshot) =
                owned_snapshot(options.family, &source_root, &binding_id, SystemTime::now())
            {
                monitor.refresh_from_disk(&options.runtime_binding_root);
                monitor.apply(
                    std::slice::from_mut(&mut snapshot),
                    SystemTime::now(),
                    crate::runtime::observe_windows_process,
                );
                final_snapshot = Some(snapshot);
            }
            return Ok(RunOutcome {
                status,
                runtime_binding_id: binding_id,
                final_snapshot,
            });
        }
        thread::sleep(POLL_INTERVAL);
    }
}

const PI_RPC_TIME: Duration = Duration::from_secs(180);
const PI_RPC_EXIT: Duration = Duration::from_secs(20);
const PI_RPC_POLL: Duration = Duration::from_millis(250);
const PI_RPC_PROMPT_ID: &str = "prompt-1";
const PI_RPC_EOF_REAP: Duration = Duration::from_secs(1);
const PI_RPC_GONE_CONFIRM: Duration = Duration::from_secs(5);

/// Result of one stdout wait on the Pi RPC transport.
enum PiFrameWait {
    Frame(Vec<u8>),
    ReadError(String),
    TimedOut,
    /// Stdout reached EOF while the channel is fully drained.
    ChannelClosed,
}

/// Confirmation that the exact PID + creation time no longer exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExactGone {
    Gone,
    StillAlive,
    /// The exact process query itself failed; the reaped child handle
    /// remains the authoritative exit confirmation.
    Unverifiable,
}

/// Injectable view of the owned Pi RPC child. Production binds the real
/// `PiChild`; tests bind a fake transport so timeout and read-error cleanup
/// can be verified in milliseconds instead of a real 180s wait on a real
/// Node child.
trait PiTransport {
    fn send(&mut self, value: serde_json::Value) -> Result<(), String>;
    fn recv_frame(&mut self, timeout: Duration) -> PiFrameWait;
    fn try_wait_child(&mut self) -> Result<Option<ExitStatus>, String>;
    fn wait_child_exit(&mut self, timeout: Duration) -> Result<Option<ExitStatus>, String>;
    fn close_stdin(&mut self);
    fn detach_frame_reader(&mut self);
    /// Kill the owned child (if still running) and block until its real exit
    /// status has been reaped. Never synthesizes an exit status.
    fn kill_and_confirm_exit(&mut self) -> Result<ExitStatus, String>;
    /// Observe the exact PID + creation time.
    fn observe_exact(&mut self, process_id: u32, started_at: SystemTime) -> ProcessObservation;
    /// Confirm the exact PID + creation time disappeared after a kill.
    fn confirm_exact_gone(&mut self, process_id: u32, started_at: SystemTime) -> ExactGone;
}

#[derive(Debug)]
enum PiWait {
    Frame,
    ChildExited(ExitStatus),
    Timeout,
    ReadError(String),
}
/// Everything the prompt phase and its abnormal cleanup need to know about
/// the exact runtime binding.
struct PiPromptContext<'a> {
    binding_id: &'a str,
    cwd: &'a Path,
    evidence_root: &'a Path,
    runtime_binding_root: &'a Path,
    process_id: u32,
    process_started_at: SystemTime,
    prompt: &'a str,
    timeout: Duration,
}

/// Outcome of an abnormal-exit cleanup attempt.
#[derive(Debug)]
struct AbnormalCleanupOutcome {
    /// True only when a complete exact binding was confirmed, the exact child
    /// was verified gone, and the launch record abnormal evidence persisted.
    recorded_lost: bool,
    detail: String,
}

#[derive(Debug)]
enum PromptPhaseResult {
    Settled,
    ChildExited {
        status: ExitStatus,
        cleanup: AbnormalCleanupOutcome,
    },
    Failed {
        message: String,
        cleanup: AbnormalCleanupOutcome,
    },
}
struct PiChild {
    child: Child,
    stdin: Option<ChildStdin>,
    frames: Receiver<Result<Vec<u8>, String>>,
    frame_reader: Option<thread::JoinHandle<()>>,
}

impl PiChild {
    fn close_stdin(&mut self) {
        self.stdin.take();
    }

    fn wait_for_exit(&mut self, timeout: Duration) -> Result<Option<ExitStatus>, String> {
        let deadline = SystemTime::now() + timeout;
        loop {
            if let Some(status) = self.try_wait_child()? {
                return Ok(Some(status));
            }
            if SystemTime::now() >= deadline {
                return Ok(None);
            }
            thread::sleep(PI_RPC_POLL);
        }
    }

    /// The frame reader thread is deliberately never joined: after a hard
    /// kill a spawned grandchild may keep the stdout pipe open, and evidence
    /// has already been persisted by the main loop as frames arrived.
    fn detach_frame_reader(&mut self) {
        self.frame_reader.take();
    }
}

impl PiTransport for PiChild {
    fn send(&mut self, value: serde_json::Value) -> Result<(), String> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or_else(|| "Pi RPC stdin is already closed".to_string())?;
        let mut encoded = serde_json::to_vec(&value).map_err(|error| error.to_string())?;
        encoded.push(b'\n');
        stdin
            .write_all(&encoded)
            .and_then(|_| stdin.flush())
            .map_err(|error| format!("cannot write Pi RPC command: {error}"))
    }

    fn recv_frame(&mut self, timeout: Duration) -> PiFrameWait {
        match self.frames.recv_timeout(timeout) {
            Ok(Ok(bytes)) => PiFrameWait::Frame(bytes),
            Ok(Err(message)) => PiFrameWait::ReadError(message),
            Err(RecvTimeoutError::Timeout) => PiFrameWait::TimedOut,
            Err(RecvTimeoutError::Disconnected) => PiFrameWait::ChannelClosed,
        }
    }

    fn try_wait_child(&mut self) -> Result<Option<ExitStatus>, String> {
        self.child
            .try_wait()
            .map_err(|error| format!("cannot query Pi RPC process: {error}"))
    }

    fn wait_child_exit(&mut self, timeout: Duration) -> Result<Option<ExitStatus>, String> {
        self.wait_for_exit(timeout)
    }

    fn close_stdin(&mut self) {
        self.close_stdin();
    }

    fn detach_frame_reader(&mut self) {
        self.detach_frame_reader();
    }

    fn kill_and_confirm_exit(&mut self) -> Result<ExitStatus, String> {
        self.close_stdin();
        if self.child.try_wait().ok().flatten().is_none() {
            self.child
                .kill()
                .map_err(|error| format!("cannot kill Pi RPC child: {error}"))?;
        }
        self.child
            .wait()
            .map_err(|error| format!("cannot wait for Pi RPC child exit: {error}"))
    }

    fn observe_exact(&mut self, process_id: u32, started_at: SystemTime) -> ProcessObservation {
        crate::runtime::observe_windows_process(process_id, started_at)
    }

    fn confirm_exact_gone(&mut self, process_id: u32, started_at: SystemTime) -> ExactGone {
        let deadline = SystemTime::now() + PI_RPC_GONE_CONFIRM;
        loop {
            match crate::runtime::observe_windows_process(process_id, started_at) {
                ProcessObservation::Missing | ProcessObservation::CreationTimeMismatch { .. } => {
                    return ExactGone::Gone;
                }
                ProcessObservation::Alive => {
                    if SystemTime::now() >= deadline {
                        return ExactGone::StillAlive;
                    }
                    thread::sleep(PI_RPC_POLL);
                }
                ProcessObservation::Unreachable(_) => return ExactGone::Unverifiable,
            }
        }
    }
}

impl Drop for PiChild {
    fn drop(&mut self) {
        self.close_stdin();
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        // Drop the handle to detach: the reader thread exits when its pipes
        // close or when this process exits, and it never blocks process exit.
        self.frame_reader.take();
    }
}

fn run_pi(pi: &PiRunOptions, options: &RunOptions) -> Result<RunOutcome, String> {
    if !pi.node_executable.is_file() {
        return Err(format!(
            "Node executable does not exist: {}; pass --pi-node-exe or AGENT_OBSERVER_PI_NODE_EXE",
            pi.node_executable.display()
        ));
    }
    if !pi.pi_cli_js.is_file() {
        return Err(format!(
            "Pi CLI bundle does not exist: {}; pass --pi-cli-js or AGENT_OBSERVER_PI_CLI_JS",
            pi.pi_cli_js.display()
        ));
    }
    if pi.session_dir.as_os_str().is_empty() {
        return Err(
            "run pi requires --pi-session-dir or AGENT_OBSERVER_PI_RPC_SESSION_ROOT".to_string(),
        );
    }
    if pi.prompt.trim().is_empty() {
        return Err("run pi requires exactly one non-empty prompt after --".to_string());
    }
    fs::create_dir_all(&options.runtime_binding_root).map_err(|error| {
        format!(
            "cannot create runtime binding root {}: {error}",
            options.runtime_binding_root.display()
        )
    })?;
    fs::create_dir_all(&pi.session_dir).map_err(|error| {
        format!(
            "cannot create Pi session directory {}: {error}",
            pi.session_dir.display()
        )
    })?;
    let evidence_root = options.runtime_binding_root.join("pi-rpc");
    fs::create_dir_all(&evidence_root).map_err(|error| {
        format!(
            "cannot create Pi evidence directory {}: {error}",
            evidence_root.display()
        )
    })?;
    if !options.cwd.is_dir() {
        return Err(format!("run cwd does not exist: {}", options.cwd.display()));
    }

    let binding_id = new_pi_binding_id();
    let launched_at = SystemTime::now();
    let evidence_file = evidence_root.join(format!("{binding_id}.jsonl"));
    let mut evidence = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&evidence_file)
        .map_err(|error| format!("cannot open {}: {error}", evidence_file.display()))?;
    let mut write_record = |value: serde_json::Value| -> Result<(), String> {
        writeln!(evidence, "{value}")
            .and_then(|_| evidence.flush())
            .map_err(|error| format!("cannot write {}: {error}", evidence_file.display()))
    };

    let mut transport = spawn_pi_child(pi, &options.cwd)?;
    let process_id = transport.child.id();
    let process_started_at = match wait_for_process_start(process_id) {
        Ok(started_at) => started_at,
        Err(message) => {
            let _ = transport.child.kill();
            let _ = transport.child.wait();
            return Err(message);
        }
    };

    let record_path = options
        .runtime_binding_root
        .join(format!("{binding_id}.json"));
    let launch_record = LaunchRecord::new(
        record_path,
        binding_id.clone(),
        AgentFamily::Pi,
        process_id,
        process_started_at,
        Some(options.cwd.to_string_lossy().into_owned()),
        launched_at,
        "pi-rpc-owned-stdio",
    );
    launch_record.persist().map_err(|message| {
        let _ = transport.child.kill();
        let _ = transport.child.wait();
        format!("cannot persist Pi launch record; child was stopped: {message}")
    })?;

    let mut state = pi_rpc::PiRpcState::new(binding_id.clone());
    let now = SystemTime::now();
    state.mark_process_alive(now);
    write_record(pi_rpc::redact_process_alive(&binding_id, &options.cwd, now))?;

    let observer_instance_id = format!("observe-pi-{}-{}", process_id, unix_millis(launched_at));
    let mut monitor = RuntimeMonitor::load(&options.runtime_binding_root, observer_instance_id);

    transport.send(serde_json::json!({"id": "state-1", "type": "get_state"}))?;
    match wait_pi_frame(
        &mut transport,
        PI_RPC_TIME,
        pi_rpc::is_get_state_response,
        |frame, at| {
            state.absorb_frame(frame, PI_RPC_PROMPT_ID, at);
            write_record(pi_rpc::redact_frame(
                frame,
                &binding_id,
                &options.cwd,
                Some(PI_RPC_PROMPT_ID),
                at,
            ))
        },
    )? {
        PiWait::Frame => {}
        PiWait::ChildExited(_) | PiWait::ReadError(_) => {
            return Err(
                "Pi child exited before get_state returned a native session id".to_string(),
            );
        }
        PiWait::Timeout => {
            return Err("Pi did not answer get_state within the timeout".to_string());
        }
    }
    let state_id = state
        .native_session_id
        .clone()
        .ok_or_else(|| "Pi get_state did not return a native session id".to_string())?;
    if state.session_name.as_deref() != Some(pi.name.as_str()) && !pi.name.is_empty() {
        return Err(format!(
            "Pi get_state sessionName ({}) does not match --name ({})",
            state.session_name.as_deref().unwrap_or("<none>"),
            pi.name
        ));
    }
    persist_pi_binding(
        &evidence_root,
        &binding_id,
        &state,
        process_id,
        process_started_at,
        &options.cwd,
        false,
    )?;
    eprintln!("pi rpc: bound native session {state_id}");

    // Keep the launch record identity alive and confirm the exact child is
    // running before the prompt starts.
    apply_pi_monitor(
        &mut monitor,
        &mut state,
        &options.runtime_binding_root,
        &options.cwd,
        SystemTime::now(),
    );

    let ctx = PiPromptContext {
        binding_id: &binding_id,
        cwd: &options.cwd,
        evidence_root: &evidence_root,
        runtime_binding_root: &options.runtime_binding_root,
        process_id,
        process_started_at,
        prompt: &pi.prompt,
        timeout: PI_RPC_TIME,
    };
    let mut record = launch_record;
    let prompt_result = drive_pi_prompt(
        &mut transport,
        &ctx,
        &mut state,
        &mut record,
        &mut monitor,
        &mut write_record,
    );
    match prompt_result {
        PromptPhaseResult::Settled => {
            let exit_status =
                complete_normal_exit(&mut transport, &ctx, &mut state, &mut write_record)?;
            let final_snapshot = final_pi_snapshot(&mut monitor, &mut state, options);
            Ok(RunOutcome {
                status: exit_status,
                runtime_binding_id: binding_id,
                final_snapshot,
            })
        }
        PromptPhaseResult::ChildExited { status, cleanup } => {
            eprintln!(
                "pi rpc: abnormal exit; cleanup recorded_lost={}: {}",
                cleanup.recorded_lost, cleanup.detail
            );
            transport.detach_frame_reader();
            let final_snapshot = final_pi_snapshot(&mut monitor, &mut state, options);
            Ok(RunOutcome {
                status,
                runtime_binding_id: binding_id,
                final_snapshot,
            })
        }
        PromptPhaseResult::Failed { message, cleanup } => {
            eprintln!(
                "pi rpc: prompt failed; cleanup recorded_lost={}: {}",
                cleanup.recorded_lost, cleanup.detail
            );
            Err(message)
        }
    }
}

/// Drive the single outstanding prompt until agent_settled. Any failure
/// (timeout, stdout read error, evidence write error, child exit) routes
/// through `abort_active_prompt`, which persists exact abnormal-exit
/// evidence when and only when the runtime binding is complete.
fn drive_pi_prompt(
    transport: &mut dyn PiTransport,
    ctx: &PiPromptContext<'_>,
    state: &mut pi_rpc::PiRpcState,
    record: &mut LaunchRecord,
    monitor: &mut RuntimeMonitor,
    write_record: &mut dyn FnMut(serde_json::Value) -> Result<(), String>,
) -> PromptPhaseResult {
    if let Err(message) = transport.send(serde_json::json!({
        "id": PI_RPC_PROMPT_ID,
        "type": "prompt",
        "message": ctx.prompt,
    })) {
        let cleanup = abort_active_prompt(transport, ctx, state, record, write_record);
        return PromptPhaseResult::Failed { message, cleanup };
    }
    let outcome = wait_pi_frame(
        transport,
        ctx.timeout,
        |frame| frame.get("type").and_then(serde_json::Value::as_str) == Some("agent_settled"),
        |frame, at| absorb_prompt_frame(ctx, state, record, monitor, write_record, frame, at),
    );
    match outcome {
        Ok(PiWait::Frame) => PromptPhaseResult::Settled,
        Ok(PiWait::ChildExited(status)) => {
            let cleanup = abort_active_prompt(transport, ctx, state, record, write_record);
            PromptPhaseResult::ChildExited { status, cleanup }
        }
        Ok(PiWait::Timeout) => {
            let message = "Pi prompt did not settle within the timeout".to_string();
            let cleanup = abort_active_prompt(transport, ctx, state, record, write_record);
            PromptPhaseResult::Failed { message, cleanup }
        }
        Ok(PiWait::ReadError(message)) => {
            let cleanup = abort_active_prompt(transport, ctx, state, record, write_record);
            PromptPhaseResult::Failed { message, cleanup }
        }
        Err(message) => {
            let cleanup = abort_active_prompt(transport, ctx, state, record, write_record);
            PromptPhaseResult::Failed { message, cleanup }
        }
    }
}

fn absorb_prompt_frame(
    ctx: &PiPromptContext<'_>,
    state: &mut pi_rpc::PiRpcState,
    _record: &mut LaunchRecord,
    monitor: &mut RuntimeMonitor,
    write_record: &mut dyn FnMut(serde_json::Value) -> Result<(), String>,
    frame: &serde_json::Value,
    at: SystemTime,
) -> Result<(), String> {
    state.absorb_frame(frame, PI_RPC_PROMPT_ID, at);
    let frame_type = frame.get("type").and_then(serde_json::Value::as_str);
    if frame_type == Some("agent_start") {
        persist_pi_binding(
            ctx.evidence_root,
            ctx.binding_id,
            state,
            ctx.process_id,
            ctx.process_started_at,
            ctx.cwd,
            true,
        )?;
    }
    // Persist the frame evidence *before* any slow process polling so a peer
    // watch can never observe the child missing while this frame's semantic
    // is not yet durable in the evidence file.
    write_record(pi_rpc::redact_frame(
        frame,
        ctx.binding_id,
        ctx.cwd,
        state.active_runtime_id.as_deref(),
        at,
    ))?;
    // Poll the process only on lifecycle frames; per-frame polling of
    // streaming updates would backlog the evidence write loop for tens of
    // seconds after a kill. The monitor persists the launch record identity
    // (native session id + active runtime id) as a side effect.
    if matches!(
        frame_type,
        Some("agent_start" | "agent_end" | "agent_settled")
    ) {
        apply_pi_monitor(
            monitor,
            state,
            ctx.runtime_binding_root,
            ctx.cwd,
            SystemTime::now(),
        );
    }
    Ok(())
}

/// Abnormal-exit cleanup for an active prompt. Records exact LOST evidence
/// only when the runtime binding is complete (native session id, active
/// prompt, host instance identity, PID + creation time, and a prior exact
/// alive observation), the exact child is re-confirmed and then verified
/// gone after the kill. Otherwise the exit cause stays UNKNOWN.
///
/// The launch record's abnormal evidence is persisted independently of the
/// protocol JSONL: even if the JSONL write fails, a restarted Observer can
/// still recover exact LOST from the launch record.
fn abort_active_prompt(
    transport: &mut dyn PiTransport,
    ctx: &PiPromptContext<'_>,
    state: &mut pi_rpc::PiRpcState,
    record: &mut LaunchRecord,
    write_record: &mut dyn FnMut(serde_json::Value) -> Result<(), String>,
) -> AbnormalCleanupOutcome {
    let binding_complete = state.native_session_id.is_some()
        && state.active_runtime_id.is_some()
        && !state.saw_agent_settled
        && state.saw_process_alive;
    if !binding_complete {
        // Incomplete exact binding: never guess LOST. A restarted Observer
        // must keep UNKNOWN. The owned child is still stopped.
        transport.close_stdin();
        let _ = transport.kill_and_confirm_exit();
        return AbnormalCleanupOutcome {
            recorded_lost: false,
            detail: "exact binding incomplete; exit cause stays UNKNOWN".to_string(),
        };
    }

    // Re-confirm the exact PID + creation time before the kill. A Missing or
    // mismatched observation means the child already disappeared on its own;
    // the child handle reaping below remains the authoritative confirmation.
    let pre_observation = transport.observe_exact(ctx.process_id, ctx.process_started_at);
    if transport.kill_and_confirm_exit().is_err() {
        return AbnormalCleanupOutcome {
            recorded_lost: false,
            detail: format!(
                "exact child exit could not be confirmed (pre-kill observation: {pre_observation:?})"
            ),
        };
    }
    match transport.confirm_exact_gone(ctx.process_id, ctx.process_started_at) {
        ExactGone::Gone | ExactGone::Unverifiable => {}
        ExactGone::StillAlive => {
            return AbnormalCleanupOutcome {
                recorded_lost: false,
                detail: "exact child still alive after the kill; no LOST recorded".to_string(),
            };
        }
    }

    let at = SystemTime::now();
    // The launch record abnormal evidence is the durable LOST proof and is
    // persisted independently of the protocol JSONL below.
    record.native_session_id = state.native_session_id.clone();
    record.active_runtime_id = state.active_runtime_id.clone();
    record.abnormal_exit_observed_at = Some(at);
    let persist_result = record.persist();
    // Best-effort protocol evidence; its failure does not undo the launch
    // record, and its success does not depend on the launch record.
    let evidence_result = write_record(pi_rpc::redact_process_exit(
        ctx.binding_id,
        ctx.cwd,
        "abnormal",
        true,
        at,
    ));
    // Attention keeps its last state (for example WORKING); a crash never
    // produces RESULT_READY.
    state.mark_abnormal_process_exit(at, true);
    match persist_result {
        Ok(()) => AbnormalCleanupOutcome {
            recorded_lost: true,
            detail: format!(
                "exact abnormal exit persisted (protocol JSONL write: {})",
                if evidence_result.is_ok() {
                    "ok"
                } else {
                    "failed"
                }
            ),
        },
        Err(message) => AbnormalCleanupOutcome {
            recorded_lost: false,
            detail: format!("cannot persist launch record abnormal evidence: {message}"),
        },
    }
}

/// Complete a normally settled run. Order is fixed: the agent_settled
/// evidence is already durable; RESULT_READY + LIVE_IDLE is the only legal
/// state until the exact child has really exited. Only after the real exit
/// is observed do we record the normal process exit (DEAD + DETACHED).
fn complete_normal_exit(
    transport: &mut dyn PiTransport,
    ctx: &PiPromptContext<'_>,
    state: &mut pi_rpc::PiRpcState,
    write_record: &mut dyn FnMut(serde_json::Value) -> Result<(), String>,
) -> Result<ExitStatus, String> {
    eprintln!("pi rpc: settled at {}", unix_millis(SystemTime::now()));
    transport.close_stdin();
    eprintln!("pi rpc: stdin closed at {}", unix_millis(SystemTime::now()));
    let exit_status = transport
        .wait_child_exit(PI_RPC_EXIT)?
        .ok_or_else(|| "Pi RPC process did not exit after stdin closed".to_string())?;
    eprintln!("pi rpc: child exited at {}", unix_millis(SystemTime::now()));
    transport.detach_frame_reader();
    let at = SystemTime::now();
    state.mark_normal_process_exit(at);
    write_record(pi_rpc::redact_process_exit(
        ctx.binding_id,
        ctx.cwd,
        "normal",
        false,
        at,
    ))?;
    eprintln!(
        "pi rpc: normal-exit record written at {}",
        unix_millis(SystemTime::now())
    );
    Ok(exit_status)
}

fn spawn_pi_child(pi: &PiRunOptions, cwd: &Path) -> Result<PiChild, String> {
    let mut command = Command::new(&pi.node_executable);
    command
        .arg(&pi.pi_cli_js)
        .args(["--mode", "rpc", "--session-dir"])
        .arg(&pi.session_dir)
        .args(["--name", &pi.name])
        .args([
            "--no-extensions",
            "--no-skills",
            "--no-prompt-templates",
            "--no-context-files",
            "--no-themes",
            "--no-tools",
            "--no-approve",
        ])
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    if let Some(provider) = &pi.provider {
        command.args(["--provider", provider]);
    }
    if let Some(model) = &pi.model {
        command.args(["--model", model]);
    }
    if let Some(thinking) = &pi.thinking {
        command.args(["--thinking", thinking]);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("cannot start Pi RPC: {error}"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Pi RPC stdout was not created".to_string())?;
    let frames = pi_rpc::spawn_frame_reader(stdout);
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| "Pi RPC stdin was not created".to_string())?;
    Ok(PiChild {
        child,
        stdin: Some(stdin),
        frames,
        frame_reader: None,
    })
}

fn wait_pi_frame(
    transport: &mut dyn PiTransport,
    timeout: Duration,
    mut done: impl FnMut(&serde_json::Value) -> bool,
    mut on_frame: impl FnMut(&serde_json::Value, SystemTime) -> Result<(), String>,
) -> Result<PiWait, String> {
    let deadline = SystemTime::now() + timeout;
    loop {
        let remaining = deadline
            .duration_since(SystemTime::now())
            .unwrap_or(Duration::ZERO);
        if remaining.is_zero() {
            return Ok(PiWait::Timeout);
        }
        match transport.recv_frame(remaining.min(PI_RPC_POLL)) {
            PiFrameWait::Frame(bytes) => {
                if bytes.is_empty() {
                    continue;
                }
                let Some(frame) = pi_rpc::parse_line(&bytes) else {
                    continue;
                };
                let observed_at = SystemTime::now();
                on_frame(&frame, observed_at)?;
                if done(&frame) {
                    return Ok(PiWait::Frame);
                }
            }
            PiFrameWait::ReadError(message) => return Ok(PiWait::ReadError(message)),
            PiFrameWait::TimedOut => {
                if let Some(status) = transport.try_wait_child()? {
                    return Ok(PiWait::ChildExited(status));
                }
            }
            PiFrameWait::ChannelClosed => {
                // Stdout EOF raced ahead of the process status: wait for the
                // real exit status, or fail explicitly. A success exit
                // status is never synthesized.
                let reap_deadline = SystemTime::now() + PI_RPC_EOF_REAP;
                loop {
                    if let Some(status) = transport.try_wait_child()? {
                        return Ok(PiWait::ChildExited(status));
                    }
                    if SystemTime::now() >= reap_deadline {
                        return Ok(PiWait::ReadError(
                            "Pi RPC stdout closed before the child exit status could be observed"
                                .to_string(),
                        ));
                    }
                    thread::sleep(Duration::from_millis(25));
                }
            }
        }
    }
}

fn apply_pi_monitor(
    monitor: &mut RuntimeMonitor,
    state: &mut pi_rpc::PiRpcState,
    runtime_binding_root: &Path,
    cwd: &Path,
    now: SystemTime,
) {
    let Some(mut snapshot) = state.to_snapshot(Some(cwd.to_string_lossy().into_owned())) else {
        return;
    };
    monitor.refresh_from_disk(runtime_binding_root);
    monitor.apply(
        std::slice::from_mut(&mut snapshot),
        now,
        crate::runtime::observe_windows_process,
    );
}

fn final_pi_snapshot(
    monitor: &mut RuntimeMonitor,
    state: &mut pi_rpc::PiRpcState,
    options: &RunOptions,
) -> Option<SessionSnapshot> {
    let now = SystemTime::now();
    let mut snapshot = state.to_snapshot(Some(options.cwd.to_string_lossy().into_owned()))?;
    monitor.refresh_from_disk(&options.runtime_binding_root);
    monitor.apply(
        std::slice::from_mut(&mut snapshot),
        now,
        crate::runtime::observe_windows_process,
    );
    Some(snapshot)
}

fn persist_pi_binding(
    evidence_root: &Path,
    binding_id: &str,
    state: &pi_rpc::PiRpcState,
    process_id: u32,
    process_started_at: SystemTime,
    cwd: &Path,
    active: bool,
) -> Result<(), String> {
    let suffix = if active {
        "binding-active.json"
    } else {
        "binding.json"
    };
    let path = evidence_root.join(format!("{binding_id}.{suffix}"));
    let value = serde_json::json!({
        "observer_schema": 2,
        "record_type": "pi_rpc_runtime_binding",
        "runtime_binding_id": binding_id,
        "native_session_id": state.native_session_id,
        "active_runtime_id": state.active_runtime_id,
        "host_instance_id": crate::runtime::host_instance_id(process_id, process_started_at),
        "process_id": process_id,
        "process_started_at_unix_ms": unix_millis(process_started_at),
        "cwd": cwd.to_string_lossy(),
        "binding_source": "observer-owned Pi RPC child + same-child get_state",
        "active": active,
    });
    fs::write(&path, format!("{value}\n"))
        .map_err(|error| format!("cannot write {}: {error}", path.display()))
}

fn new_pi_binding_id() -> String {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO);
    let counter = BINDING_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!(
        "pi-binding-{}-{}-{}",
        std::process::id(),
        elapsed.as_nanos(),
        counter
    )
}

fn stream_codex_stdout(
    stdout: impl std::io::Read,
    event_path: &Path,
    runtime_binding_id: &str,
    cwd: &Path,
) -> Result<(), String> {
    let mut event_file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(event_path)
        .map_err(|error| format!("cannot open {}: {error}", event_path.display()))?;
    for line in BufReader::new(stdout).lines() {
        let line = line.map_err(|error| format!("cannot read Codex stdout: {error}"))?;
        println!("{line}");
        if let Some(redacted) =
            codex_exec::redact_raw_event(&line, runtime_binding_id, cwd, SystemTime::now())
        {
            writeln!(event_file, "{redacted}")
                .and_then(|_| event_file.flush())
                .map_err(|error| format!("cannot write {}: {error}", event_path.display()))?;
        }
    }
    Ok(())
}

fn owned_snapshot(
    family: RunFamily,
    source_root: &Path,
    runtime_binding_id: &str,
    now: SystemTime,
) -> Option<SessionSnapshot> {
    let snapshots = match family {
        RunFamily::Claude => {
            claude_hook::discover(source_root, now, Duration::from_secs(300), true)
        }
        RunFamily::Codex => codex_exec::discover(source_root, now, Duration::from_secs(300), true),
        RunFamily::Pi => unreachable!("run pi is dispatched to run_pi before run_cli"),
    };
    snapshots
        .into_iter()
        .find(|snapshot| snapshot.runtime_binding_id.as_deref() == Some(runtime_binding_id))
}

fn wait_for_process_start(process_id: u32) -> Result<SystemTime, String> {
    for _ in 0..40 {
        match query_process(process_id) {
            Ok(Some(identity)) => return Ok(identity.started_at),
            Ok(None) => thread::sleep(Duration::from_millis(25)),
            Err(message) => return Err(message),
        }
    }
    Err(format!(
        "launched process {process_id} exited before its creation time could be recorded"
    ))
}

fn write_claude_support(
    runtime_binding_root: &Path,
    runtime_binding_id: &str,
) -> Result<PathBuf, String> {
    let support = runtime_binding_root
        .join("launch-support")
        .join(runtime_binding_id);
    fs::create_dir_all(&support)
        .map_err(|error| format!("cannot create {}: {error}", support.display()))?;
    let hook_script = support.join("claude-observer-hook.ps1");
    fs::write(&hook_script, CLAUDE_HOOK_SCRIPT)
        .map_err(|error| format!("cannot write {}: {error}", hook_script.display()))?;
    let events = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PermissionDenied",
        "PostToolUse",
        "Notification",
        "Stop",
        "StopFailure",
        "SessionEnd",
    ];
    let mut hooks = serde_json::Map::new();
    for event in events {
        hooks.insert(
            event.to_string(),
            serde_json::json!([{
                "hooks": [{
                    "type": "command",
                    "command": "powershell.exe",
                    "args": [
                        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                        hook_script, "-Surface", "cli", "-RuntimeBindingId",
                        runtime_binding_id
                    ]
                }]
            }]),
        );
    }
    let settings = support.join("claude-hooks.json");
    let value = serde_json::json!({ "hooks": hooks });
    fs::write(&settings, format!("{value}\n"))
        .map_err(|error| format!("cannot write {}: {error}", settings.display()))?;
    Ok(settings)
}

fn new_binding_id() -> String {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO);
    let counter = BINDING_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!(
        "binding-{}-{}-{}",
        std::process::id(),
        elapsed.as_nanos(),
        counter
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_claude_settings_pass_only_binding_metadata() {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-runner-settings-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        let settings = write_claude_support(&root, "binding-test").expect("write settings");
        let text = fs::read_to_string(settings).unwrap();

        assert!(text.contains("binding-test"));
        assert!(text.contains("claude-observer-hook.ps1"));
        assert!(!text.contains("prompt_id"));
        assert!(!text.contains("tool_input"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn binding_ids_are_unique_within_the_process() {
        assert_ne!(new_binding_id(), new_binding_id());
    }
}

#[cfg(test)]
mod pi_prompt_tests {
    use super::*;
    use crate::model::{AttentionState, HostLiveness, SessionLiveness};
    use serde_json::{Value, json};

    struct FakePiTransport {
        frames: Vec<PiFrameWait>,
        sent: Vec<Value>,
        try_wait_status: Option<ExitStatus>,
        wait_exit_status: Option<ExitStatus>,
        observe: ProcessObservation,
        exact_gone: ExactGone,
        stdin_closed: bool,
        killed: bool,
    }

    impl FakePiTransport {
        fn new(frames: Vec<PiFrameWait>) -> Self {
            Self {
                frames,
                sent: Vec::new(),
                try_wait_status: None,
                wait_exit_status: None,
                observe: ProcessObservation::Alive,
                exact_gone: ExactGone::Gone,
                stdin_closed: false,
                killed: false,
            }
        }
    }

    impl PiTransport for FakePiTransport {
        fn send(&mut self, value: serde_json::Value) -> Result<(), String> {
            self.sent.push(value);
            Ok(())
        }

        fn recv_frame(&mut self, timeout: Duration) -> PiFrameWait {
            if self.frames.is_empty() {
                // Avoid a busy loop while still honoring an injectable,
                // millisecond-scale timeout.
                thread::sleep(timeout.min(Duration::from_millis(10)));
                return PiFrameWait::TimedOut;
            }
            self.frames.remove(0)
        }

        fn try_wait_child(&mut self) -> Result<Option<ExitStatus>, String> {
            Ok(self.try_wait_status)
        }

        fn wait_child_exit(&mut self, _timeout: Duration) -> Result<Option<ExitStatus>, String> {
            Ok(self.wait_exit_status)
        }

        fn close_stdin(&mut self) {
            self.stdin_closed = true;
        }

        fn detach_frame_reader(&mut self) {}

        fn kill_and_confirm_exit(&mut self) -> Result<ExitStatus, String> {
            if let Some(status) = self.try_wait_status {
                // Already exited: no kill needed, the handle reaps the status.
                return Ok(status);
            }
            self.killed = true;
            self.stdin_closed = true;
            self.try_wait_status = Some(ExitStatus::default());
            self.try_wait_status
                .ok_or_else(|| "fake child had no status".to_string())
        }

        fn observe_exact(
            &mut self,
            _process_id: u32,
            _started_at: SystemTime,
        ) -> ProcessObservation {
            self.observe.clone()
        }

        fn confirm_exact_gone(&mut self, _process_id: u32, _started_at: SystemTime) -> ExactGone {
            self.exact_gone
        }
    }

    struct PromptRun {
        result: PromptPhaseResult,
        transport: FakePiTransport,
        root: PathBuf,
        binding_id: String,
        cwd: PathBuf,
        process_id: u32,
        process_started_at: SystemTime,
        state: pi_rpc::PiRpcState,
    }

    fn agent_frame(frame_type: &str) -> PiFrameWait {
        PiFrameWait::Frame(serde_json::to_vec(&json!({"type": frame_type})).unwrap())
    }

    /// Runs the production prompt phase against a fake transport over a real
    /// disposable evidence root. The pre-prompt evidence (exact alive
    /// observation + same-child get_state) mirrors what run_pi writes, so the
    /// redacted JSONL and launch record on disk are produced by the production
    /// evidence writers only.
    fn run_prompt_phase(transport: FakePiTransport, timeout: Duration) -> PromptRun {
        run_prompt_phase_with_writer(transport, timeout, false)
    }

    fn run_prompt_phase_with_writer(
        transport: FakePiTransport,
        timeout: Duration,
        fail_evidence_writes: bool,
    ) -> PromptRun {
        static FIXTURE_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let fixture_index = FIXTURE_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "agent-observer-pi-prompt-{}-{}-{fixture_index}",
            std::process::id(),
            unix_millis(SystemTime::now())
        ));
        let evidence_root = root.join("pi-rpc");
        let cwd = root.join("ws");
        fs::create_dir_all(&evidence_root).unwrap();
        fs::create_dir_all(&cwd).unwrap();
        let binding_id = "pi-binding-test".to_string();
        let evidence_file = evidence_root.join(format!("{binding_id}.jsonl"));
        let started_at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
        let process_id = 432_199;

        let mut state = pi_rpc::PiRpcState::new(binding_id.clone());
        let now = SystemTime::now();
        state.mark_process_alive(now);
        let get_state = json!({
            "type": "response", "id": "state-1", "command": "get_state", "success": true,
            "data": {
                "sessionId": "pi-session-1", "sessionFile": "s1.jsonl",
                "sessionName": "Pi並行テスト_日本語",
                "isStreaming": false, "isCompacting": false, "pendingMessageCount": 0
            }
        });
        state.absorb_frame(&get_state, PI_RPC_PROMPT_ID, now);
        {
            let mut evidence = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&evidence_file)
                .unwrap();
            writeln!(
                evidence,
                "{}",
                pi_rpc::redact_process_alive(&binding_id, &cwd, now)
            )
            .unwrap();
            writeln!(
                evidence,
                "{}",
                pi_rpc::redact_frame(&get_state, &binding_id, &cwd, Some(PI_RPC_PROMPT_ID), now)
            )
            .unwrap();
            evidence.flush().unwrap();
        }

        let record = LaunchRecord::new(
            root.join(format!("{binding_id}.json")),
            binding_id.clone(),
            crate::model::AgentFamily::Pi,
            process_id,
            started_at,
            Some(cwd.to_string_lossy().into_owned()),
            now,
            "pi-rpc-owned-stdio",
        );
        record.persist().unwrap();

        let mut monitor = RuntimeMonitor::load(&root, "observer-test");
        let mut transport = transport;
        let ctx = PiPromptContext {
            binding_id: &binding_id,
            cwd: &cwd,
            evidence_root: &evidence_root,
            runtime_binding_root: &root,
            process_id,
            process_started_at: started_at,
            // The prompt text must never reach any evidence file.
            prompt: "secret prompt body",
            timeout,
        };
        let mut record = record;
        let mut state = state;
        let result = {
            let mut evidence = OpenOptions::new()
                .append(true)
                .open(&evidence_file)
                .unwrap();
            let mut write_record = |value: serde_json::Value| -> Result<(), String> {
                if fail_evidence_writes {
                    return Err("simulated protocol JSONL write failure".to_string());
                }
                writeln!(evidence, "{value}")
                    .and_then(|_| evidence.flush())
                    .map_err(|error| format!("cannot write evidence: {error}"))
            };
            drive_pi_prompt(
                &mut transport,
                &ctx,
                &mut state,
                &mut record,
                &mut monitor,
                &mut write_record,
            )
        };
        PromptRun {
            result,
            transport,
            root,
            binding_id,
            cwd,
            process_id,
            process_started_at: started_at,
            state,
        }
    }

    fn replay_pi(root: &Path) -> Vec<crate::model::SessionSnapshot> {
        pi_rpc::discover(
            &root.join("pi-rpc"),
            SystemTime::now(),
            Duration::from_secs(3600),
            true,
        )
    }

    fn launch_record_json(run: &PromptRun) -> Value {
        let text = fs::read_to_string(run.root.join(format!("{}.json", run.binding_id))).unwrap();
        serde_json::from_str(&text).unwrap()
    }

    fn evidence_text(run: &PromptRun) -> String {
        fs::read_to_string(
            run.root
                .join("pi-rpc")
                .join(format!("{}.jsonl", run.binding_id)),
        )
        .unwrap()
    }

    #[test]
    fn active_prompt_timeout_cleanup_records_exact_lost() {
        let transport = FakePiTransport::new(vec![agent_frame("agent_start")]);
        let run = run_prompt_phase(transport, Duration::from_millis(400));
        let PromptPhaseResult::Failed { message, cleanup } = &run.result else {
            panic!("expected timeout failure, got {:?}", run.result);
        };
        assert!(message.contains("did not settle"));
        assert!(cleanup.recorded_lost);
        assert!(run.transport.killed);

        // The launch record carries the durable abnormal evidence with the
        // full exact binding identity.
        let record = launch_record_json(&run);
        assert!(record["abnormal_exit_observed_at_unix_ms"].is_u64());
        assert_eq!(record["native_session_id"], "pi-session-1");
        assert_eq!(record["active_runtime_id"], "prompt-1");
        assert_eq!(record["process_id"], 432_199);

        // The redacted protocol JSONL also carries the abnormal exit.
        let text = evidence_text(&run);
        assert!(text.contains("\"observer_process_exit\""));
        assert!(text.contains("\"abnormal\""));
        assert!(!text.contains("secret prompt body"));

        // Replay: exact LOST while attention keeps WORKING; never RESULT_READY.
        let snapshots = replay_pi(&run.root);
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].attention_state, AttentionState::Working);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);

        // A fresh Observer recovers exact LOST from the persisted evidence.
        let mut snapshots = snapshots;
        let mut fresh = RuntimeMonitor::load(&run.root, "observer-fresh");
        fresh.apply(&mut snapshots, SystemTime::now(), |_, _| {
            ProcessObservation::Missing
        });
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_ne!(snapshots[0].attention_state, AttentionState::ResultReady);
        fs::remove_dir_all(&run.root).ok();
    }

    #[test]
    fn active_prompt_read_error_cleanup_records_exact_lost() {
        let transport = FakePiTransport::new(vec![
            agent_frame("agent_start"),
            PiFrameWait::ReadError("cannot read Pi RPC stdout: broken pipe".to_string()),
        ]);
        let run = run_prompt_phase(transport, Duration::from_secs(5));
        let PromptPhaseResult::Failed { message, cleanup } = &run.result else {
            panic!("expected read-error failure, got {:?}", run.result);
        };
        assert!(message.contains("broken pipe"));
        assert!(cleanup.recorded_lost);
        assert!(run.transport.killed);

        let record = launch_record_json(&run);
        assert!(record["abnormal_exit_observed_at_unix_ms"].is_u64());

        let snapshots = replay_pi(&run.root);
        assert_eq!(snapshots[0].attention_state, AttentionState::Working);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_ne!(snapshots[0].attention_state, AttentionState::ResultReady);
        fs::remove_dir_all(&run.root).ok();
    }

    #[test]
    fn pre_binding_error_keeps_unknown_never_lost() {
        // No agent_start: the exact binding is incomplete (no active prompt),
        // so a timeout must leave the exit cause UNKNOWN, never LOST.
        let transport = FakePiTransport::new(Vec::new());
        let run = run_prompt_phase(transport, Duration::from_millis(200));
        let PromptPhaseResult::Failed { cleanup, .. } = &run.result else {
            panic!("expected failure, got {:?}", run.result);
        };
        assert!(!cleanup.recorded_lost);

        let record = launch_record_json(&run);
        assert!(record["abnormal_exit_observed_at_unix_ms"].is_null());

        let snapshots = replay_pi(&run.root);
        assert_eq!(snapshots.len(), 1);
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);

        // A fresh Observer that never saw the child alive keeps UNKNOWN.
        let mut snapshots = snapshots;
        let mut fresh = RuntimeMonitor::load(&run.root, "observer-fresh");
        fresh.apply(&mut snapshots, SystemTime::now(), |_, _| {
            ProcessObservation::Missing
        });
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Unknown);
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
        fs::remove_dir_all(&run.root).ok();
    }

    #[test]
    fn child_exit_during_prompt_records_exact_lost_without_result_ready() {
        let mut transport = FakePiTransport::new(vec![agent_frame("agent_start")]);
        transport.try_wait_status = Some(ExitStatus::default());
        let run = run_prompt_phase(transport, Duration::from_secs(5));
        let PromptPhaseResult::ChildExited { cleanup, .. } = &run.result else {
            panic!("expected child exit, got {:?}", run.result);
        };
        assert!(cleanup.recorded_lost);
        // The child had already exited; cleanup must not issue a second kill.
        assert!(!run.transport.killed);

        let record = launch_record_json(&run);
        assert!(record["abnormal_exit_observed_at_unix_ms"].is_u64());

        let snapshots = replay_pi(&run.root);
        assert_eq!(snapshots[0].attention_state, AttentionState::Working);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_ne!(snapshots[0].attention_state, AttentionState::ResultReady);
        fs::remove_dir_all(&run.root).ok();
    }

    #[test]
    fn settled_run_stays_alive_live_idle_until_the_real_exit() {
        let transport = FakePiTransport::new(vec![
            agent_frame("agent_start"),
            PiFrameWait::Frame(
                serde_json::to_vec(&json!({
                    "type": "agent_end",
                    "messages": [{"role": "assistant", "stopReason": "stop"}]
                }))
                .unwrap(),
            ),
            agent_frame("agent_settled"),
        ]);
        let run = run_prompt_phase(transport, Duration::from_secs(5));
        assert!(matches!(run.result, PromptPhaseResult::Settled));
        // stdin is still open: the exit sequence has not started.
        assert!(!run.transport.stdin_closed);

        // No exit evidence yet: the last evidence record is agent_settled.
        let text = evidence_text(&run);
        let last_line = text.lines().last().unwrap();
        assert!(last_line.contains("\"agent_settled\""));
        assert!(!text.contains("\"observer_process_exit\""));

        // Replay in the legal window: RESULT_READY + ALIVE + LIVE_IDLE.
        let snapshots = replay_pi(&run.root);
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].attention_state, AttentionState::ResultReady);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Alive);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::LiveIdle);

        // The prompt text never reached the evidence.
        assert!(!text.contains("secret prompt body"));
        fs::remove_dir_all(&run.root).ok();
    }

    #[test]
    fn normal_completion_writes_exit_evidence_only_after_real_exit() {
        let transport = FakePiTransport::new(vec![
            agent_frame("agent_start"),
            PiFrameWait::Frame(
                serde_json::to_vec(&json!({
                    "type": "agent_end",
                    "messages": [{"role": "assistant", "stopReason": "stop"}]
                }))
                .unwrap(),
            ),
            agent_frame("agent_settled"),
        ]);
        let mut run = run_prompt_phase(transport, Duration::from_secs(5));
        assert!(matches!(run.result, PromptPhaseResult::Settled));

        // The fake child only reports a reaped exit status now; until then
        // complete_normal_exit must not record any exit evidence.
        run.transport.wait_exit_status = Some(ExitStatus::default());
        let evidence_file = run
            .root
            .join("pi-rpc")
            .join(format!("{}.jsonl", run.binding_id));
        let status = {
            let ctx = PiPromptContext {
                binding_id: &run.binding_id,
                cwd: &run.cwd,
                evidence_root: &run.root.join("pi-rpc"),
                runtime_binding_root: &run.root,
                process_id: run.process_id,
                process_started_at: run.process_started_at,
                prompt: "secret prompt body",
                timeout: Duration::from_secs(5),
            };
            let mut state = std::mem::replace(
                &mut run.state,
                pi_rpc::PiRpcState::new(run.binding_id.clone()),
            );
            let mut transport =
                std::mem::replace(&mut run.transport, FakePiTransport::new(Vec::new()));
            let mut evidence = OpenOptions::new()
                .append(true)
                .open(&evidence_file)
                .unwrap();
            let mut write_record = |value: serde_json::Value| -> Result<(), String> {
                writeln!(evidence, "{value}")
                    .and_then(|_| evidence.flush())
                    .map_err(|error| format!("cannot write evidence: {error}"))
            };
            let status =
                complete_normal_exit(&mut transport, &ctx, &mut state, &mut write_record).unwrap();
            run.state = state;
            run.transport = transport;
            status
        };
        assert_eq!(status.code(), Some(0));
        assert!(run.transport.stdin_closed);

        // Only now does the exit evidence exist, and it is the last record.
        let text = evidence_text(&run);
        let last_line = text.lines().last().unwrap();
        assert!(last_line.contains("\"observer_process_exit\""));
        assert!(last_line.contains("\"normal\""));

        // Replay after the real exit: RESULT_READY + DEAD + DETACHED, never LOST.
        let snapshots = replay_pi(&run.root);
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].attention_state, AttentionState::ResultReady);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Detached);
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
        fs::remove_dir_all(&run.root).ok();
    }

    #[test]
    fn launch_record_abnormal_evidence_survives_protocol_write_failure() {
        // Every protocol JSONL write fails during the prompt phase; the
        // launch record abnormal evidence must still persist independently
        // so a restarted Observer can recover exact LOST.
        let transport = FakePiTransport::new(vec![agent_frame("agent_start")]);
        let run = run_prompt_phase_with_writer(transport, Duration::from_millis(300), true);
        let PromptPhaseResult::Failed { cleanup, .. } = &run.result else {
            panic!("expected failure, got {:?}", run.result);
        };
        assert!(cleanup.recorded_lost);

        let record = launch_record_json(&run);
        assert!(record["abnormal_exit_observed_at_unix_ms"].is_u64());
        assert_eq!(record["native_session_id"], "pi-session-1");
        assert_eq!(record["active_runtime_id"], "prompt-1");

        // The protocol JSONL never received the exit record...
        let text = evidence_text(&run);
        assert!(!text.contains("\"observer_process_exit\""));

        // ...but a fresh Observer still recovers exact LOST from the launch
        // record's persisted abnormal evidence.
        let mut snapshots = replay_pi(&run.root);
        assert_eq!(snapshots.len(), 1);
        let mut fresh = RuntimeMonitor::load(&run.root, "observer-fresh");
        fresh.apply(&mut snapshots, SystemTime::now(), |_, _| {
            ProcessObservation::Missing
        });
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_ne!(snapshots[0].attention_state, AttentionState::ResultReady);
        fs::remove_dir_all(&run.root).ok();
    }

    #[test]
    fn stdout_eof_without_a_real_status_errors_instead_of_faking_success() {
        let mut transport = FakePiTransport::new(vec![PiFrameWait::ChannelClosed]);
        let outcome = wait_pi_frame(
            &mut transport,
            Duration::from_secs(2),
            |_| false,
            |_, _| Ok(()),
        );
        match outcome {
            Ok(PiWait::ReadError(message)) => {
                assert!(message.contains("stdout closed"));
            }
            other => panic!("expected an explicit read error, got {other:?}"),
        }
    }

    #[test]
    fn stdout_eof_with_a_reaped_status_reports_the_real_child_exit() {
        let mut transport = FakePiTransport::new(vec![PiFrameWait::ChannelClosed]);
        transport.try_wait_status = Some(ExitStatus::default());
        let outcome = wait_pi_frame(
            &mut transport,
            Duration::from_secs(2),
            |_| false,
            |_, _| Ok(()),
        );
        assert!(matches!(outcome, Ok(PiWait::ChildExited(_))));
    }
}
