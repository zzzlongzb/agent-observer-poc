use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const POLL_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Scenario {
    Identity,
    Normal,
    Kill,
}

impl Scenario {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "identity" => Ok(Self::Identity),
            "normal" => Ok(Self::Normal),
            "kill" => Ok(Self::Kill),
            _ => Err(format!("unknown Pi RPC probe scenario: {value}")),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Identity => "identity",
            Self::Normal => "normal",
            Self::Kill => "kill",
        }
    }
}

#[derive(Debug)]
struct Options {
    scenario: Scenario,
    cwd: PathBuf,
    session_dir: PathBuf,
    evidence_dir: PathBuf,
    name: String,
    prompt: String,
    provider: Option<String>,
    model: Option<String>,
    thinking: Option<String>,
    node_executable: PathBuf,
    pi_cli_js: PathBuf,
    timeout: Duration,
    hold_after_state: Duration,
    aging_after: Duration,
    stale_after: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AssistantOutcome {
    Normal,
    Failed,
    Unknown,
}

#[derive(Debug)]
struct ProbeState {
    runtime_binding_id: String,
    native_session_id: Option<String>,
    session_file: Option<String>,
    session_name: Option<String>,
    active_runtime_id: Option<String>,
    attention_state: &'static str,
    attention_evidence: &'static str,
    session_liveness: &'static str,
    host_liveness: &'static str,
    last_attention_evidence_at_ms: Option<u128>,
    last_session_liveness_evidence_at_ms: Option<u128>,
    last_host_liveness_observed_at_ms: Option<u128>,
    last_assistant_outcome: AssistantOutcome,
    is_streaming: Option<bool>,
    is_compacting: Option<bool>,
    pending_message_count: Option<u64>,
    saw_agent_start: bool,
    saw_agent_end: bool,
    saw_agent_settled: bool,
    saw_process_alive: bool,
    false_green: bool,
}

impl ProbeState {
    fn new(runtime_binding_id: String) -> Self {
        Self {
            runtime_binding_id,
            native_session_id: None,
            session_file: None,
            session_name: None,
            active_runtime_id: None,
            attention_state: "UNKNOWN",
            attention_evidence: "no Pi attention evidence",
            session_liveness: "UNKNOWN",
            host_liveness: "UNKNOWN",
            last_attention_evidence_at_ms: None,
            last_session_liveness_evidence_at_ms: None,
            last_host_liveness_observed_at_ms: None,
            last_assistant_outcome: AssistantOutcome::Unknown,
            is_streaming: None,
            is_compacting: None,
            pending_message_count: None,
            saw_agent_start: false,
            saw_agent_end: false,
            saw_agent_settled: false,
            saw_process_alive: false,
            false_green: false,
        }
    }

    fn absorb_frame(&mut self, frame: &Value, prompt_id: &str, observed_at_ms: u128) {
        if is_get_state_response(frame) {
            let data = &frame["data"];
            self.native_session_id = nonempty(data, "sessionId").or(self.native_session_id.take());
            self.session_file = nonempty(data, "sessionFile").or(self.session_file.take());
            self.session_name = nonempty(data, "sessionName").or(self.session_name.take());
            self.is_streaming = data.get("isStreaming").and_then(Value::as_bool);
            self.is_compacting = data.get("isCompacting").and_then(Value::as_bool);
            self.pending_message_count = data.get("pendingMessageCount").and_then(Value::as_u64);
            if self.session_liveness == "UNKNOWN" {
                self.session_liveness = if self.is_streaming == Some(true) {
                    "LIVE_ACTIVE"
                } else {
                    "LIVE_IDLE"
                };
                self.last_session_liveness_evidence_at_ms = Some(observed_at_ms);
            }
            return;
        }

        match frame.get("type").and_then(Value::as_str) {
            Some("agent_start") => {
                self.saw_agent_start = true;
                self.attention_state = "WORKING";
                self.attention_evidence = "Pi RPC agent_start received by Observer";
                self.active_runtime_id = Some(prompt_id.to_string());
                self.session_liveness = "LIVE_ACTIVE";
                self.last_attention_evidence_at_ms = Some(observed_at_ms);
                self.last_session_liveness_evidence_at_ms = Some(observed_at_ms);
            }
            Some("agent_end") => {
                self.saw_agent_end = true;
                self.last_assistant_outcome = assistant_outcome(frame);
                // agent_end is intentionally non-terminal. Pi may still retry,
                // compact, or consume a queued continuation.
            }
            Some("agent_settled") => {
                self.saw_agent_settled = true;
                self.active_runtime_id = None;
                self.session_liveness = "LIVE_IDLE";
                self.last_session_liveness_evidence_at_ms = Some(observed_at_ms);
                match self.last_assistant_outcome {
                    AssistantOutcome::Normal => {
                        self.attention_state = "RESULT_READY";
                        self.attention_evidence =
                            "Pi RPC agent_settled after normal assistant termination";
                    }
                    AssistantOutcome::Failed => {
                        self.attention_state = "INTERRUPTED";
                        self.attention_evidence =
                            "Pi RPC agent_settled after failed or aborted assistant termination";
                    }
                    AssistantOutcome::Unknown => {
                        self.attention_state = "UNKNOWN";
                        self.attention_evidence =
                            "Pi RPC agent_settled without a recognized assistant outcome";
                    }
                }
                self.last_attention_evidence_at_ms = Some(observed_at_ms);
            }
            Some("auto_retry_start")
            | Some("compaction_start")
            | Some("summarization_retry_scheduled")
            | Some("summarization_retry_attempt_start") => {
                self.attention_state = "WORKING";
                self.attention_evidence = "Pi RPC retry or compaction activity";
                self.last_attention_evidence_at_ms = Some(observed_at_ms);
            }
            Some("extension_ui_request") if is_blocking_ui_request(frame) => {
                self.attention_state = "NEEDS_ME";
                self.attention_evidence = "Pi RPC blocking extension UI request";
                self.last_attention_evidence_at_ms = Some(observed_at_ms);
            }
            _ => {}
        }
    }

    fn mark_process_alive(&mut self, observed_at_ms: u128) {
        self.saw_process_alive = true;
        self.host_liveness = "ALIVE";
        self.last_host_liveness_observed_at_ms = Some(observed_at_ms);
    }

    fn mark_normal_process_exit(&mut self, observed_at_ms: u128) {
        self.host_liveness = "DEAD";
        self.last_host_liveness_observed_at_ms = Some(observed_at_ms);
        if self.active_runtime_id.is_none() {
            self.session_liveness = "DETACHED";
            self.last_session_liveness_evidence_at_ms = Some(observed_at_ms);
        }
    }

    fn mark_abnormal_process_exit(&mut self, observed_at_ms: u128, exact_binding: bool) {
        self.host_liveness = "DEAD";
        self.last_host_liveness_observed_at_ms = Some(observed_at_ms);
        if exact_binding
            && self.saw_process_alive
            && self.native_session_id.is_some()
            && self.active_runtime_id.is_some()
            && !self.saw_agent_settled
        {
            self.session_liveness = "LOST";
            self.last_session_liveness_evidence_at_ms = Some(observed_at_ms);
        } else {
            self.session_liveness = "UNKNOWN";
            self.last_session_liveness_evidence_at_ms = Some(observed_at_ms);
        }
        self.false_green = self.attention_state == "RESULT_READY";
    }

    fn freshness(
        &self,
        now_ms: u128,
        aging_after: Duration,
        stale_after: Duration,
    ) -> &'static str {
        let Some(at) = self.last_attention_evidence_at_ms else {
            return "NONE";
        };
        let age = now_ms.saturating_sub(at);
        if age > stale_after.as_millis() {
            "STALE"
        } else if age > aging_after.as_millis() {
            "AGING"
        } else {
            "FRESH"
        }
    }
}

struct RpcChild {
    child: Child,
    stdin: Option<ChildStdin>,
    frames: Receiver<Result<Vec<u8>, String>>,
    reader_thread: Option<thread::JoinHandle<()>>,
    stderr_thread: Option<thread::JoinHandle<()>>,
    process_started_at_ms: u128,
}

impl RpcChild {
    fn send(&mut self, value: Value) -> Result<(), String> {
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

    fn close_stdin(&mut self) {
        self.stdin.take();
    }

    fn wait_for_exit(
        &mut self,
        timeout: Duration,
    ) -> Result<Option<std::process::ExitStatus>, String> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = self
                .child
                .try_wait()
                .map_err(|error| format!("cannot query Pi RPC process: {error}"))?
            {
                return Ok(Some(status));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            thread::sleep(POLL_INTERVAL);
        }
    }

    fn join_readers(&mut self) -> Result<(), String> {
        if let Some(thread) = self.reader_thread.take() {
            thread
                .join()
                .map_err(|_| "Pi RPC stdout reader panicked".to_string())?;
        }
        if let Some(thread) = self.stderr_thread.take() {
            thread
                .join()
                .map_err(|_| "Pi RPC stderr reader panicked".to_string())?;
        }
        Ok(())
    }
}

impl Drop for RpcChild {
    fn drop(&mut self) {
        self.close_stdin();
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        if let Some(thread) = self.reader_thread.take() {
            let _ = thread.join();
        }
        if let Some(thread) = self.stderr_thread.take() {
            let _ = thread.join();
        }
    }
}

fn main() {
    if let Err(message) = real_main() {
        eprintln!("{message}");
        std::process::exit(2);
    }
}

fn real_main() -> Result<(), String> {
    let options = parse_options(env::args().skip(1).collect())?;
    validate_options(&options)?;
    fs::create_dir_all(&options.session_dir)
        .map_err(|error| format!("cannot create {}: {error}", options.session_dir.display()))?;
    fs::create_dir_all(&options.evidence_dir)
        .map_err(|error| format!("cannot create {}: {error}", options.evidence_dir.display()))?;

    let runtime_binding_id = new_binding_id();
    let mut state = ProbeState::new(runtime_binding_id.clone());
    let events_path = options.evidence_dir.join("protocol.redacted.jsonl");
    let snapshots_path = options.evidence_dir.join("snapshots.jsonl");
    let stderr_path = options.evidence_dir.join("stderr.log");
    write_manifest(&options, &runtime_binding_id)?;

    let mut rpc = spawn_pi(&options, &stderr_path)?;
    let process_id = rpc.child.id();
    state.mark_process_alive(now_ms());
    write_snapshot(&snapshots_path, &state, &options, "process_alive")?;

    rpc.send(json!({"id":"state-1","type":"get_state"}))?;
    wait_until(
        &mut rpc,
        options.timeout,
        is_get_state_response,
        |frame, at| {
            append_redacted(&events_path, frame, at)?;
            state.absorb_frame(frame, "prompt-1", at);
            write_snapshot(&snapshots_path, &state, &options, "rpc_frame")
        },
    )?;

    persist_binding(
        "binding.json",
        &options,
        &state,
        process_id,
        rpc.process_started_at_ms,
    )?;

    match options.scenario {
        Scenario::Identity => run_identity(&options, &mut rpc, &mut state, &snapshots_path)?,
        Scenario::Normal => run_normal(
            &options,
            &mut rpc,
            &mut state,
            &events_path,
            &snapshots_path,
        )?,
        Scenario::Kill => run_kill(
            &options,
            &mut rpc,
            &mut state,
            &events_path,
            &snapshots_path,
        )?,
    }

    let acceptance_passed = acceptance_passed(&options, &state);
    write_summary(
        &options,
        &state,
        process_id,
        rpc.process_started_at_ms,
        acceptance_passed,
    )?;
    println!(
        "{}",
        json!({
            "scenario": options.scenario.as_str(),
            "runtime_binding_id": state.runtime_binding_id,
            "native_session_id": state.native_session_id,
            "session_name": state.session_name,
            "attention_state": state.attention_state,
            "evidence_freshness": state.freshness(now_ms(), options.aging_after, options.stale_after),
            "host_liveness": state.host_liveness,
            "session_liveness": state.session_liveness,
            "false_green": state.false_green,
            "acceptance_passed": acceptance_passed,
            "evidence_dir": options.evidence_dir,
        })
    );
    if !acceptance_passed {
        return Err(format!(
            "Pi RPC {} scenario did not meet its acceptance conditions",
            options.scenario.as_str()
        ));
    }
    Ok(())
}

fn run_identity(
    options: &Options,
    rpc: &mut RpcChild,
    state: &mut ProbeState,
    snapshots_path: &Path,
) -> Result<(), String> {
    if !options.hold_after_state.is_zero() {
        thread::sleep(options.hold_after_state);
    }
    rpc.close_stdin();
    if rpc.wait_for_exit(Duration::from_secs(10))?.is_none() {
        rpc.child
            .kill()
            .map_err(|error| format!("cannot stop identity probe: {error}"))?;
        let _ = rpc.child.wait();
    }
    rpc.join_readers()?;
    state.mark_normal_process_exit(now_ms());
    write_snapshot(snapshots_path, state, options, "normal_process_exit")
}

fn run_normal(
    options: &Options,
    rpc: &mut RpcChild,
    state: &mut ProbeState,
    events_path: &Path,
    snapshots_path: &Path,
) -> Result<(), String> {
    rpc.send(json!({
        "id": "prompt-1",
        "type": "prompt",
        "message": options.prompt,
    }))?;
    wait_until(
        rpc,
        options.timeout,
        |frame| frame.get("type").and_then(Value::as_str) == Some("agent_start"),
        |frame, at| {
            append_redacted(events_path, frame, at)?;
            state.absorb_frame(frame, "prompt-1", at);
            write_snapshot(snapshots_path, state, options, "rpc_frame")
        },
    )?;
    persist_binding(
        "binding-active.json",
        options,
        state,
        rpc.child.id(),
        rpc.process_started_at_ms,
    )?;
    wait_until(
        rpc,
        options.timeout,
        |frame| frame.get("type").and_then(Value::as_str) == Some("agent_settled"),
        |frame, at| {
            append_redacted(events_path, frame, at)?;
            state.absorb_frame(frame, "prompt-1", at);
            write_snapshot(snapshots_path, state, options, "rpc_frame")
        },
    )?;
    rpc.close_stdin();
    if rpc.wait_for_exit(Duration::from_secs(15))?.is_none() {
        return Err("Pi RPC process did not exit after stdin closed".to_string());
    }
    rpc.join_readers()?;
    state.mark_normal_process_exit(now_ms());
    write_snapshot(snapshots_path, state, options, "normal_process_exit")
}

fn run_kill(
    options: &Options,
    rpc: &mut RpcChild,
    state: &mut ProbeState,
    events_path: &Path,
    snapshots_path: &Path,
) -> Result<(), String> {
    rpc.send(json!({
        "id": "prompt-1",
        "type": "prompt",
        "message": options.prompt,
    }))?;
    wait_until(
        rpc,
        options.timeout,
        |frame| frame.get("type").and_then(Value::as_str) == Some("agent_start"),
        |frame, at| {
            append_redacted(events_path, frame, at)?;
            state.absorb_frame(frame, "prompt-1", at);
            write_snapshot(snapshots_path, state, options, "rpc_frame")
        },
    )?;
    if state.attention_state != "WORKING" || state.active_runtime_id.as_deref() != Some("prompt-1")
    {
        return Err("Pi kill probe did not establish an exact active prompt".to_string());
    }
    persist_binding(
        "binding-active.json",
        options,
        state,
        rpc.child.id(),
        rpc.process_started_at_ms,
    )?;
    if !process_matches(rpc.child.id(), rpc.process_started_at_ms)? {
        return Err("Pi process identity changed before the exact kill".to_string());
    }

    rpc.child
        .kill()
        .map_err(|error| format!("cannot kill exact Pi RPC process: {error}"))?;
    let _ = rpc
        .child
        .wait()
        .map_err(|error| format!("cannot wait for killed Pi RPC process: {error}"))?;
    rpc.close_stdin();
    rpc.join_readers()?;
    state.mark_abnormal_process_exit(now_ms(), true);
    write_snapshot(
        snapshots_path,
        state,
        options,
        "exact_abnormal_process_exit",
    )?;
    if state.attention_state == "RESULT_READY" || state.session_liveness != "LOST" {
        return Err("exact Pi crash produced an unsafe terminal state".to_string());
    }

    thread::sleep(options.aging_after + Duration::from_millis(50));
    write_snapshot(snapshots_path, state, options, "freshness_aging")?;
    let elapsed = options.aging_after + Duration::from_millis(50);
    if options.stale_after > elapsed {
        thread::sleep(options.stale_after - elapsed + Duration::from_millis(50));
    }
    write_snapshot(snapshots_path, state, options, "freshness_stale")
}

fn spawn_pi(options: &Options, stderr_path: &Path) -> Result<RpcChild, String> {
    let mut command = Command::new(&options.node_executable);
    command
        .arg(&options.pi_cli_js)
        .args(["--mode", "rpc", "--session-dir"])
        .arg(&options.session_dir)
        .args(["--name", &options.name])
        .args([
            "--no-extensions",
            "--no-skills",
            "--no-prompt-templates",
            "--no-context-files",
            "--no-themes",
            "--no-tools",
            "--no-approve",
        ])
        .current_dir(&options.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(provider) = &options.provider {
        command.args(["--provider", provider]);
    }
    if let Some(model) = &options.model {
        command.args(["--model", model]);
    }
    if let Some(thinking) = &options.thinking {
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
    let process_started_at_ms = wait_for_process_start(child.id())?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| "Pi RPC stdin was not created".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Pi RPC stdout was not created".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "Pi RPC stderr was not created".to_string())?;
    let (tx, frames) = mpsc::channel();
    let reader_thread = thread::spawn(move || read_lf_frames(stdout, tx));
    let stderr_path = stderr_path.to_path_buf();
    let stderr_thread = thread::spawn(move || {
        if let Ok(mut file) = File::create(stderr_path) {
            let mut reader = BufReader::new(stderr);
            let _ = std::io::copy(&mut reader, &mut file);
        }
    });
    Ok(RpcChild {
        child,
        stdin: Some(stdin),
        frames,
        reader_thread: Some(reader_thread),
        stderr_thread: Some(stderr_thread),
        process_started_at_ms,
    })
}

fn read_lf_frames(stdout: impl Read, tx: mpsc::Sender<Result<Vec<u8>, String>>) {
    let mut reader = BufReader::new(stdout);
    loop {
        let mut bytes = Vec::new();
        match reader.read_until(b'\n', &mut bytes) {
            Ok(0) => break,
            Ok(_) => {
                if bytes.last() == Some(&b'\n') {
                    bytes.pop();
                }
                if bytes.last() == Some(&b'\r') {
                    bytes.pop();
                }
                if tx.send(Ok(bytes)).is_err() {
                    break;
                }
            }
            Err(error) => {
                let _ = tx.send(Err(format!("cannot read Pi RPC stdout: {error}")));
                break;
            }
        }
    }
}

fn wait_until(
    rpc: &mut RpcChild,
    timeout: Duration,
    mut done: impl FnMut(&Value) -> bool,
    mut on_frame: impl FnMut(&Value, u128) -> Result<(), String>,
) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("timed out waiting for Pi RPC evidence".to_string());
        }
        match rpc
            .frames
            .recv_timeout(remaining.min(Duration::from_millis(250)))
        {
            Ok(Ok(bytes)) => {
                if bytes.is_empty() {
                    continue;
                }
                let frame: Value = serde_json::from_slice(&bytes)
                    .map_err(|error| format!("Pi RPC emitted invalid JSONL: {error}"))?;
                let observed_at_ms = now_ms();
                on_frame(&frame, observed_at_ms)?;
                if done(&frame) {
                    return Ok(());
                }
            }
            Ok(Err(message)) => return Err(message),
            Err(RecvTimeoutError::Timeout) => {
                if let Some(status) = rpc
                    .child
                    .try_wait()
                    .map_err(|error| format!("cannot query Pi RPC child: {error}"))?
                {
                    return Err(format!(
                        "Pi RPC exited before required evidence with status {status}"
                    ));
                }
            }
            Err(RecvTimeoutError::Disconnected) => {
                return Err("Pi RPC stdout closed before required evidence".to_string());
            }
        }
    }
}

fn assistant_outcome(frame: &Value) -> AssistantOutcome {
    let Some(messages) = frame.get("messages").and_then(Value::as_array) else {
        return AssistantOutcome::Unknown;
    };
    messages
        .iter()
        .rev()
        .find(|message| message.get("role").and_then(Value::as_str) == Some("assistant"))
        .map(assistant_message_outcome)
        .unwrap_or(AssistantOutcome::Unknown)
}

fn assistant_message_outcome(message: &Value) -> AssistantOutcome {
    match message.get("stopReason").and_then(Value::as_str) {
        Some("stop") => AssistantOutcome::Normal,
        Some("error" | "aborted" | "length") => AssistantOutcome::Failed,
        _ => AssistantOutcome::Unknown,
    }
}

fn is_get_state_response(frame: &Value) -> bool {
    frame.get("type").and_then(Value::as_str) == Some("response")
        && frame.get("command").and_then(Value::as_str) == Some("get_state")
        && frame.get("success").and_then(Value::as_bool) == Some(true)
}

fn is_blocking_ui_request(frame: &Value) -> bool {
    matches!(
        frame.get("method").and_then(Value::as_str),
        Some("select" | "confirm" | "input" | "editor")
    )
}

fn nonempty(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn append_redacted(path: &Path, frame: &Value, observed_at_ms: u128) -> Result<(), String> {
    let redacted = redact_frame(frame, observed_at_ms);
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("cannot open {}: {error}", path.display()))?;
    writeln!(file, "{redacted}")
        .map_err(|error| format!("cannot write {}: {error}", path.display()))
}

fn redact_frame(frame: &Value, observed_at_ms: u128) -> Value {
    let frame_type = frame
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let mut value = json!({
        "observer_schema": 1,
        "source": "pi-rpc-owned-stdio",
        "observed_at_unix_ms": observed_at_ms,
        "type": frame_type,
    });
    for key in ["id", "command", "method"] {
        if let Some(text) = nonempty(frame, key) {
            value[key] = Value::String(text);
        }
    }
    if let Some(success) = frame.get("success").and_then(Value::as_bool) {
        value["success"] = Value::Bool(success);
    }
    if is_get_state_response(frame) {
        let data = &frame["data"];
        value["data"] = json!({
            "sessionId": nonempty(data, "sessionId"),
            "sessionFile": nonempty(data, "sessionFile"),
            "sessionName": nonempty(data, "sessionName"),
            "isStreaming": data.get("isStreaming").and_then(Value::as_bool),
            "isCompacting": data.get("isCompacting").and_then(Value::as_bool),
            "pendingMessageCount": data.get("pendingMessageCount").and_then(Value::as_u64),
        });
    }
    if frame_type == "agent_end" {
        value["willRetry"] = frame
            .get("willRetry")
            .and_then(Value::as_bool)
            .map(Value::Bool)
            .unwrap_or(Value::Null);
        value["assistantOutcome"] = Value::String(
            match assistant_outcome(frame) {
                AssistantOutcome::Normal => "normal",
                AssistantOutcome::Failed => "failed",
                AssistantOutcome::Unknown => "unknown",
            }
            .to_string(),
        );
    }
    if let Some(message) = frame.get("message") {
        if let Some(role) = nonempty(message, "role") {
            value["messageRole"] = Value::String(role);
        }
        if let Some(stop_reason) = nonempty(message, "stopReason") {
            value["stopReason"] = Value::String(stop_reason);
        }
    }
    if let Some(tool_name) = nonempty(frame, "toolName") {
        value["toolName"] = Value::String(tool_name);
    }
    if let Some(tool_call_id) = nonempty(frame, "toolCallId") {
        value["toolCallId"] = Value::String(tool_call_id);
    }
    value
}

fn write_manifest(options: &Options, runtime_binding_id: &str) -> Result<(), String> {
    write_json(
        &options.evidence_dir.join("manifest.json"),
        json!({
            "probe_schema": 1,
            "probe": "Pi RPC Runtime Binding Feasibility v1",
            "scenario": options.scenario.as_str(),
            "runtime_binding_id": runtime_binding_id,
            "cwd": options.cwd,
            "session_dir": options.session_dir,
            "session_name": options.name,
            "provider": options.provider,
            "model": options.model,
            "thinking": options.thinking,
            "node_executable": options.node_executable,
            "pi_cli_js": options.pi_cli_js,
            "privacy": "prompt and model output are not persisted; protocol evidence is metadata-only",
            "started_at_unix_ms": now_ms(),
        }),
    )
}

fn persist_binding(
    file_name: &str,
    options: &Options,
    state: &ProbeState,
    process_id: u32,
    process_started_at_ms: u128,
) -> Result<(), String> {
    write_json(
        &options.evidence_dir.join(file_name),
        json!({
            "observer_schema": 2,
            "record_type": "pi_rpc_runtime_binding_probe",
            "runtime_binding_id": state.runtime_binding_id,
            "native_session_id": state.native_session_id,
            "active_runtime_id": state.active_runtime_id,
            "host_instance_id": host_instance_id(process_id, process_started_at_ms),
            "process_id": process_id,
            "process_started_at_unix_ms": process_started_at_ms,
            "cwd": options.cwd,
            "binding_source": "observer-owned Pi RPC child + same-child get_state",
        }),
    )
}

fn write_snapshot(
    path: &Path,
    state: &ProbeState,
    options: &Options,
    reason: &str,
) -> Result<(), String> {
    let now = now_ms();
    let value = json!({
        "observer_schema": 2,
        "record_type": "pi_rpc_probe_snapshot",
        "reason": reason,
        "observed_at_unix_ms": now,
        "agent_family": "Pi",
        "surface": "CLI",
        "native_session_id": state.native_session_id,
        "session_display_name": state.session_name,
        "cwd": options.cwd,
        "attention_state": state.attention_state,
        "attention_evidence": state.attention_evidence,
        "evidence_freshness": state.freshness(now, options.aging_after, options.stale_after),
        "host_liveness": state.host_liveness,
        "session_liveness": state.session_liveness,
        "runtime_binding_id": state.runtime_binding_id,
        "active_runtime_id": state.active_runtime_id,
        "last_attention_evidence_at_unix_ms": state.last_attention_evidence_at_ms,
        "last_session_liveness_evidence_at_unix_ms": state.last_session_liveness_evidence_at_ms,
        "last_host_liveness_observed_at_unix_ms": state.last_host_liveness_observed_at_ms,
    });
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("cannot open {}: {error}", path.display()))?;
    writeln!(file, "{value}").map_err(|error| format!("cannot write {}: {error}", path.display()))
}

fn write_summary(
    options: &Options,
    state: &ProbeState,
    process_id: u32,
    process_started_at_ms: u128,
    acceptance_passed: bool,
) -> Result<(), String> {
    write_json(
        &options.evidence_dir.join("summary.json"),
        json!({
            "probe_schema": 1,
            "scenario": options.scenario.as_str(),
            "runtime_binding_id": state.runtime_binding_id,
            "native_session_id": state.native_session_id,
            "session_file": state.session_file,
            "session_name": state.session_name,
            "cwd": options.cwd,
            "process_id": process_id,
            "process_started_at_unix_ms": process_started_at_ms,
            "host_instance_id": host_instance_id(process_id, process_started_at_ms),
            "attention_state": state.attention_state,
            "evidence_freshness": state.freshness(now_ms(), options.aging_after, options.stale_after),
            "host_liveness": state.host_liveness,
            "session_liveness": state.session_liveness,
            "active_runtime_id": state.active_runtime_id,
            "saw_agent_start": state.saw_agent_start,
            "saw_agent_end": state.saw_agent_end,
            "saw_agent_settled": state.saw_agent_settled,
            "saw_process_alive": state.saw_process_alive,
            "false_green": state.false_green,
            "acceptance_passed": acceptance_passed,
        }),
    )
}

fn acceptance_passed(options: &Options, state: &ProbeState) -> bool {
    match options.scenario {
        Scenario::Identity => {
            state.native_session_id.is_some()
                && state.session_file.is_some()
                && state.session_name.as_deref() == Some(options.name.as_str())
                && state.saw_process_alive
                && state.session_liveness == "DETACHED"
        }
        Scenario::Normal => {
            state.saw_agent_start
                && state.saw_agent_end
                && state.saw_agent_settled
                && state.attention_state == "RESULT_READY"
                && state.session_liveness == "DETACHED"
                && !state.false_green
        }
        Scenario::Kill => {
            state.saw_agent_start
                && !state.saw_agent_settled
                && state.attention_state == "WORKING"
                && state.session_liveness == "LOST"
                && state.host_liveness == "DEAD"
                && !state.false_green
        }
    }
}

fn write_json(path: &Path, value: Value) -> Result<(), String> {
    let mut text = serde_json::to_string_pretty(&value).map_err(|error| error.to_string())?;
    text.push('\n');
    fs::write(path, text).map_err(|error| format!("cannot write {}: {error}", path.display()))
}

fn validate_options(options: &Options) -> Result<(), String> {
    if !options.cwd.is_dir() {
        return Err(format!(
            "probe cwd does not exist: {}",
            options.cwd.display()
        ));
    }
    if !options.node_executable.is_file() {
        return Err(format!(
            "Node executable does not exist: {}",
            options.node_executable.display()
        ));
    }
    if !options.pi_cli_js.is_file() {
        return Err(format!(
            "Pi CLI bundle does not exist: {}",
            options.pi_cli_js.display()
        ));
    }
    if options.aging_after >= options.stale_after {
        return Err("--aging-after-ms must be less than --stale-after-ms".to_string());
    }
    Ok(())
}

fn parse_options(args: Vec<String>) -> Result<Options, String> {
    let app_data = env::var_os("APPDATA")
        .map(PathBuf::from)
        .ok_or_else(|| "APPDATA is unavailable".to_string())?;
    let mut scenario = None;
    let mut cwd = env::current_dir().map_err(|error| error.to_string())?;
    let mut session_dir = None;
    let mut evidence_dir = None;
    let mut name = "Pi RPC feasibility".to_string();
    let mut prompt = "Reply with exactly PI_RPC_OK. Do not use tools.".to_string();
    let mut provider = None;
    let mut model = None;
    let mut thinking = None;
    let mut node_executable = PathBuf::from(r"C:\Program Files\nodejs\node.exe");
    let mut pi_cli_js =
        app_data.join(r"npm\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js");
    let mut timeout = Duration::from_secs(180);
    let mut hold_after_state = Duration::ZERO;
    let mut aging_after = Duration::from_millis(500);
    let mut stale_after = Duration::from_millis(1200);
    let mut args = args.into_iter();
    while let Some(argument) = args.next() {
        let value = |args: &mut std::vec::IntoIter<String>, name: &str| {
            args.next()
                .ok_or_else(|| format!("{name} requires a value"))
        };
        match argument.as_str() {
            "--scenario" => scenario = Some(Scenario::parse(&value(&mut args, "--scenario")?)?),
            "--cwd" => cwd = PathBuf::from(value(&mut args, "--cwd")?),
            "--session-dir" => {
                session_dir = Some(PathBuf::from(value(&mut args, "--session-dir")?))
            }
            "--evidence-dir" => {
                evidence_dir = Some(PathBuf::from(value(&mut args, "--evidence-dir")?))
            }
            "--name" => name = value(&mut args, "--name")?,
            "--prompt" => prompt = value(&mut args, "--prompt")?,
            "--provider" => provider = Some(value(&mut args, "--provider")?),
            "--model" => model = Some(value(&mut args, "--model")?),
            "--thinking" => thinking = Some(value(&mut args, "--thinking")?),
            "--node" => node_executable = PathBuf::from(value(&mut args, "--node")?),
            "--pi-cli-js" => pi_cli_js = PathBuf::from(value(&mut args, "--pi-cli-js")?),
            "--timeout-secs" => {
                timeout = parse_duration(&value(&mut args, "--timeout-secs")?, 1000)?
            }
            "--hold-after-state-ms" => {
                hold_after_state = parse_duration(&value(&mut args, "--hold-after-state-ms")?, 1)?
            }
            "--aging-after-ms" => {
                aging_after = parse_duration(&value(&mut args, "--aging-after-ms")?, 1)?
            }
            "--stale-after-ms" => {
                stale_after = parse_duration(&value(&mut args, "--stale-after-ms")?, 1)?
            }
            "--help" | "-h" => return Err(usage()),
            _ => return Err(format!("unknown argument: {argument}\n{}", usage())),
        }
    }
    Ok(Options {
        scenario: scenario.ok_or_else(|| "--scenario is required".to_string())?,
        cwd,
        session_dir: session_dir.ok_or_else(|| "--session-dir is required".to_string())?,
        evidence_dir: evidence_dir.ok_or_else(|| "--evidence-dir is required".to_string())?,
        name,
        prompt,
        provider,
        model,
        thinking,
        node_executable,
        pi_cli_js,
        timeout,
        hold_after_state,
        aging_after,
        stale_after,
    })
}

fn parse_duration(value: &str, multiplier_ms: u64) -> Result<Duration, String> {
    let number = value
        .parse::<u64>()
        .map_err(|_| format!("expected a non-negative integer duration, got {value}"))?;
    Ok(Duration::from_millis(number.saturating_mul(multiplier_ms)))
}

fn usage() -> String {
    "usage: pi_rpc_probe --scenario identity|normal|kill --cwd PATH --session-dir PATH --evidence-dir PATH [--name TEXT] [--prompt TEXT] [--provider NAME] [--model ID] [--thinking LEVEL]".to_string()
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis()
}

fn new_binding_id() -> String {
    format!("pi-binding-{}-{}", std::process::id(), now_ms())
}

fn host_instance_id(process_id: u32, started_at_ms: u128) -> String {
    let host = env::var("COMPUTERNAME").unwrap_or_else(|_| "unknown-host".to_string());
    format!("{host}:pid:{process_id}:started:{started_at_ms}")
}

fn wait_for_process_start(process_id: u32) -> Result<u128, String> {
    for _ in 0..40 {
        if let Some(started_at_ms) = query_process_start(process_id)? {
            return Ok(started_at_ms);
        }
        thread::sleep(Duration::from_millis(25));
    }
    Err(format!(
        "Pi process {process_id} exited before its creation time could be recorded"
    ))
}

fn process_matches(process_id: u32, expected_started_at_ms: u128) -> Result<bool, String> {
    Ok(query_process_start(process_id)? == Some(expected_started_at_ms))
}

fn query_process_start(process_id: u32) -> Result<Option<u128>, String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let script = format!(
            "$ErrorActionPreference='SilentlyContinue'; $p=Get-Process -Id {process_id}; if($p){{[int64]([DateTimeOffset]$p.StartTime).ToUnixTimeMilliseconds()}}"
        );
        let output = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|error| format!("cannot query Pi process creation time: {error}"))?;
        let text = String::from_utf8_lossy(&output.stdout);
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return Ok(None);
        }
        trimmed
            .parse::<u128>()
            .map(Some)
            .map_err(|_| format!("invalid process creation time: {trimmed}"))
    }
    #[cfg(not(windows))]
    {
        let _ = process_id;
        Err("Pi RPC feasibility probe is Windows-only".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> ProbeState {
        let mut state = ProbeState::new("binding-1".to_string());
        state.native_session_id = Some("session-1".to_string());
        state.mark_process_alive(1_000);
        state
    }

    #[test]
    fn agent_end_alone_never_turns_green() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", 1_100);
        state.absorb_frame(
            &json!({"type":"agent_end","willRetry":false,"messages":[{"role":"assistant","stopReason":"stop","content":"private"}]}),
            "prompt-1",
            1_200,
        );

        assert_eq!(state.attention_state, "WORKING");
        assert_eq!(state.active_runtime_id.as_deref(), Some("prompt-1"));
        assert!(!state.saw_agent_settled);
    }

    #[test]
    fn settled_after_normal_assistant_is_result_ready() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", 1_100);
        state.absorb_frame(
            &json!({"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop"}]}),
            "prompt-1",
            1_200,
        );
        state.absorb_frame(&json!({"type":"agent_settled"}), "prompt-1", 1_300);

        assert_eq!(state.attention_state, "RESULT_READY");
        assert_eq!(state.session_liveness, "LIVE_IDLE");
        assert_eq!(state.active_runtime_id, None);
    }

    #[test]
    fn settled_after_error_is_interrupted_not_green() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", 1_100);
        state.absorb_frame(
            &json!({"type":"agent_end","messages":[{"role":"assistant","stopReason":"error"}]}),
            "prompt-1",
            1_200,
        );
        state.absorb_frame(&json!({"type":"agent_settled"}), "prompt-1", 1_300);

        assert_eq!(state.attention_state, "INTERRUPTED");
        assert_ne!(state.attention_state, "RESULT_READY");
    }

    #[test]
    fn exact_active_kill_is_lost_without_false_green() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", 1_100);
        state.mark_abnormal_process_exit(1_200, true);

        assert_eq!(state.attention_state, "WORKING");
        assert_eq!(state.session_liveness, "LOST");
        assert!(!state.false_green);
    }

    #[test]
    fn missed_exit_or_inexact_binding_stays_unknown() {
        let mut missed = ProbeState::new("binding-1".to_string());
        missed.native_session_id = Some("session-1".to_string());
        missed.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", 1_100);
        missed.mark_abnormal_process_exit(1_200, true);
        assert_eq!(missed.session_liveness, "UNKNOWN");

        let mut inexact = state();
        inexact.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", 1_100);
        inexact.mark_abnormal_process_exit(1_200, false);
        assert_eq!(inexact.session_liveness, "UNKNOWN");
    }

    #[test]
    fn stale_does_not_overwrite_working() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", 1_000);

        assert_eq!(
            state.freshness(
                3_000,
                Duration::from_millis(500),
                Duration::from_millis(1_200)
            ),
            "STALE"
        );
        assert_eq!(state.attention_state, "WORKING");
    }

    #[test]
    fn only_blocking_extension_ui_requests_need_attention() {
        let mut blocking = state();
        blocking.absorb_frame(
            &json!({"type":"extension_ui_request","id":"ui-1","method":"confirm","message":"private"}),
            "prompt-1",
            1_100,
        );
        assert_eq!(blocking.attention_state, "NEEDS_ME");

        let mut notify = state();
        notify.absorb_frame(
            &json!({"type":"extension_ui_request","id":"ui-2","method":"notify","message":"private"}),
            "prompt-1",
            1_100,
        );
        assert_eq!(notify.attention_state, "UNKNOWN");
    }

    #[test]
    fn redaction_drops_prompt_and_assistant_content() {
        let raw = json!({
            "type":"agent_end",
            "willRetry":false,
            "messages":[{"role":"assistant","stopReason":"stop","content":"secret output"}],
            "prompt":"secret prompt"
        });
        let redacted = redact_frame(&raw, 1_000).to_string();

        assert!(redacted.contains("normal"));
        assert!(!redacted.contains("secret output"));
        assert!(!redacted.contains("secret prompt"));
    }

    #[test]
    fn lf_framing_does_not_split_unicode_line_separator_inside_json() {
        let (tx, rx) = mpsc::channel();
        let input = b"{\"type\":\"event\",\"text\":\"a\xE2\x80\xA8b\"}\n";
        read_lf_frames(&input[..], tx);
        let frame = rx.recv().unwrap().unwrap();
        let value: Value = serde_json::from_slice(&frame).unwrap();
        assert_eq!(value["text"], "a\u{2028}b");
        assert!(rx.try_recv().is_err());
    }
}
