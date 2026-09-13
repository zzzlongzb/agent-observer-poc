mod claude;
mod claude_desktop;
mod claude_hook;
mod codex;
mod codex_exec;
mod doctor;
mod grok;
mod host;
mod model;
mod pi;
mod pi_rpc;
mod process;
mod runner;
mod runtime;

use std::collections::BTreeMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, SystemTime};

use model::{
    AttentionState, EvidenceFreshness, HostLiveness, SessionLiveness, SessionSnapshot, age_text,
    optional_unix_millis, unix_millis,
};
use runtime::RuntimeMonitor;

struct Options {
    watch: bool,
    json: bool,
    include_stale: bool,
    interval: Duration,
    stale_after: Duration,
    record_file: Option<PathBuf>,
    cwd_filter: Option<String>,
    runtime_binding_root: Option<PathBuf>,
}

enum AppCommand {
    Observe(Options),
    Doctor { json: bool },
    Run(runner::RunOptions),
}

#[derive(Default)]
struct SnapshotCache {
    by_identity: BTreeMap<(model::AgentFamily, String), SessionSnapshot>,
}

impl SnapshotCache {
    fn refresh(
        &mut self,
        snapshots: Vec<SessionSnapshot>,
        now: SystemTime,
        stale_after: Duration,
    ) -> Vec<SessionSnapshot> {
        for snapshot in snapshots {
            let key = (snapshot.family, snapshot.native_session_id.clone());
            match self.by_identity.get_mut(&key) {
                Some(existing) => *existing = merge_snapshots(existing.clone(), snapshot),
                None => {
                    self.by_identity.insert(key, snapshot);
                }
            }
        }

        let mut retained = self.by_identity.values().cloned().collect::<Vec<_>>();
        for snapshot in &mut retained {
            // Retaining identity preserves a visible, independently aging
            // evidence record. It is not a session liveness assertion.
            snapshot.apply_evidence_freshness(now, stale_after);
        }
        retained.sort_by_key(|snapshot| std::cmp::Reverse(snapshot.last_source_activity_at));
        retained
    }

    fn store(&mut self, snapshots: &[SessionSnapshot]) {
        self.by_identity.clear();
        for snapshot in snapshots {
            self.by_identity.insert(
                (snapshot.family, snapshot.native_session_id.clone()),
                snapshot.clone(),
            );
        }
    }
}

struct SnapshotRecorder {
    path: PathBuf,
    last_recorded: BTreeMap<(model::AgentFamily, String), SnapshotFingerprint>,
}

#[derive(PartialEq, Eq)]
struct SnapshotFingerprint {
    surface: model::Surface,
    cwd: Option<String>,
    attention_state: AttentionState,
    attention_evidence: String,
    evidence_freshness: EvidenceFreshness,
    host_liveness: HostLiveness,
    host_liveness_evidence: Option<String>,
    last_host_liveness_observed_at: Option<SystemTime>,
    session_liveness: SessionLiveness,
    session_liveness_evidence: Option<String>,
    last_attention_evidence_at: Option<SystemTime>,
    last_session_liveness_evidence_at: Option<SystemTime>,
    last_source_activity_at: SystemTime,
    source: String,
    runtime_binding_id: Option<String>,
    active_runtime_id: Option<String>,
    process_id: Option<u32>,
    process_started_at: Option<SystemTime>,
    host_instance_id: Option<String>,
}

impl SnapshotRecorder {
    fn new(path: PathBuf, now: SystemTime) -> Result<Self, String> {
        let recorder = Self {
            path,
            last_recorded: BTreeMap::new(),
        };
        recorder.write_line(serde_json::json!({
            "record_type": "observer_started",
            "recorded_at_unix_ms": unix_millis(now),
        }))?;
        Ok(recorder)
    }

    fn record_changes(
        &mut self,
        snapshots: &[SessionSnapshot],
        now: SystemTime,
    ) -> Result<(), String> {
        for snapshot in snapshots {
            let key = (snapshot.family, snapshot.native_session_id.clone());
            let fingerprint = SnapshotFingerprint {
                surface: snapshot.surface,
                cwd: snapshot.cwd.clone(),
                attention_state: snapshot.attention_state,
                attention_evidence: snapshot.attention_evidence.clone(),
                evidence_freshness: snapshot.evidence_freshness,
                host_liveness: snapshot.host_liveness,
                host_liveness_evidence: snapshot.host_liveness_evidence.clone(),
                last_host_liveness_observed_at: snapshot.last_host_liveness_observed_at,
                session_liveness: snapshot.session_liveness,
                session_liveness_evidence: snapshot.session_liveness_evidence.clone(),
                last_attention_evidence_at: snapshot.last_attention_evidence_at,
                last_session_liveness_evidence_at: snapshot.last_session_liveness_evidence_at,
                last_source_activity_at: snapshot.last_source_activity_at,
                source: snapshot.source.clone(),
                runtime_binding_id: snapshot.runtime_binding_id.clone(),
                active_runtime_id: snapshot.active_runtime_id.clone(),
                process_id: snapshot
                    .runtime_binding
                    .as_ref()
                    .map(|binding| binding.process_id),
                process_started_at: snapshot
                    .runtime_binding
                    .as_ref()
                    .map(|binding| binding.process_started_at),
                host_instance_id: snapshot
                    .runtime_binding
                    .as_ref()
                    .map(|binding| binding.host_instance_id.clone()),
            };
            if self.last_recorded.get(&key) == Some(&fingerprint) {
                continue;
            }

            self.write_line(serde_json::json!({
                "record_type": "snapshot",
                "recorded_at_unix_ms": unix_millis(now),
                "agent_family": snapshot.family.to_string(),
                "surface": snapshot.surface.to_string(),
                "native_session_id": snapshot.native_session_id,
                "cwd": snapshot.cwd,
                "attention_state": snapshot.attention_state.to_string(),
                "attention_evidence": snapshot.attention_evidence,
                "evidence_freshness": snapshot.evidence_freshness.to_string(),
                "host_liveness": snapshot.host_liveness.to_string(),
                "host_liveness_evidence": snapshot.host_liveness_evidence,
                "session_liveness": snapshot.session_liveness.to_string(),
                "session_liveness_evidence": snapshot.session_liveness_evidence,
                "source": snapshot.source,
                "last_attention_evidence_unix_ms": optional_unix_millis(snapshot.last_attention_evidence_at),
                "last_session_liveness_evidence_unix_ms": optional_unix_millis(snapshot.last_session_liveness_evidence_at),
                "last_host_liveness_observed_unix_ms": optional_unix_millis(snapshot.last_host_liveness_observed_at),
                "last_source_activity_unix_ms": unix_millis(snapshot.last_source_activity_at),
                "attention_evidence_age_ms": snapshot.last_attention_evidence_at
                    .and_then(|then| now.duration_since(then).ok())
                    .unwrap_or(Duration::ZERO)
                    .as_millis(),
                "runtime_binding_id": snapshot.runtime_binding_id,
                "active_runtime_id": snapshot.active_runtime_id,
                "process_id": snapshot.runtime_binding.as_ref().map(|binding| binding.process_id),
                "process_started_at_unix_ms": snapshot
                    .runtime_binding
                    .as_ref()
                    .map(|binding| unix_millis(binding.process_started_at)),
                "host_instance_id": snapshot
                    .runtime_binding
                    .as_ref()
                    .map(|binding| binding.host_instance_id.clone()),
            }))?;
            self.last_recorded.insert(key, fingerprint);
        }
        Ok(())
    }

    fn write_line(&self, value: serde_json::Value) -> Result<(), String> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "cannot create observation record directory {}: {error}",
                    parent.display()
                )
            })?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .map_err(|error| {
                format!(
                    "cannot open observation record file {}: {error}",
                    self.path.display()
                )
            })?;
        writeln!(file, "{value}").map_err(|error| {
            format!(
                "cannot write observation record file {}: {error}",
                self.path.display()
            )
        })
    }
}

fn main() {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    if matches!(arguments.first().map(String::as_str), Some("--help" | "-h")) {
        print_usage();
        return;
    }
    let command = match command_from_args(arguments) {
        Ok(command) => command,
        Err(message) => {
            eprintln!("{message}");
            print_usage();
            std::process::exit(2);
        }
    };
    match command {
        AppCommand::Observe(options) => observe(options),
        AppCommand::Doctor { json } => run_doctor(json),
        AppCommand::Run(options) => match runner::run(options) {
            Ok(outcome) => {
                eprintln!("runtime binding: {}", outcome.runtime_binding_id);
                if let Some(snapshot) = outcome.final_snapshot {
                    eprintln!(
                        "final observer state: attention={} host={} session={}",
                        snapshot.attention_state, snapshot.host_liveness, snapshot.session_liveness
                    );
                } else {
                    eprintln!("final observer state: no exact native session evidence");
                }
                std::process::exit(outcome.status.code().unwrap_or(1));
            }
            Err(message) => {
                eprintln!("{message}");
                std::process::exit(2);
            }
        },
    }
}

fn observe(options: Options) {
    let mut recorder = match options.record_file.clone() {
        Some(path) => match SnapshotRecorder::new(path, SystemTime::now()) {
            Ok(recorder) => Some(recorder),
            Err(message) => {
                eprintln!("{message}");
                std::process::exit(2);
            }
        },
        None => None,
    };

    let mut watch_cache = SnapshotCache::default();
    let mut codex_watch = codex::WatchDiscovery::default();
    let runtime_binding_root = options.runtime_binding_root.clone().unwrap_or_else(|| {
        local_app_data_path(
            "AGENT_OBSERVER_RUNTIME_BINDING_ROOT",
            "agent-observer-poc\\runtime-bindings",
        )
    });
    let observer_instance_id = format!(
        "observer-{}-{}",
        std::process::id(),
        unix_millis(SystemTime::now())
    );
    let mut runtime_monitor = RuntimeMonitor::load(&runtime_binding_root, observer_instance_id);
    loop {
        let now = SystemTime::now();
        let codex_root = env_path("AGENT_OBSERVER_CODEX_ROOT", ".codex\\sessions");
        let claude_root = env_path("AGENT_OBSERVER_CLAUDE_ROOT", ".claude\\projects");
        let claude_hook_root = local_app_data_path(
            "AGENT_OBSERVER_CLAUDE_HOOK_ROOT",
            "agent-observer-poc\\claude-hooks",
        );
        let claude_session_root =
            env_path("AGENT_OBSERVER_CLAUDE_SESSION_ROOT", ".claude\\sessions");
        let pi_session_root = env_path("AGENT_OBSERVER_PI_SESSION_ROOT", ".pi\\agent\\sessions");
        let pi_hook_root = local_app_data_path(
            "AGENT_OBSERVER_PI_HOOK_ROOT",
            "agent-observer-poc\\pi-hooks",
        );
        let grok_session_root = env_path("AGENT_OBSERVER_GROK_SESSION_ROOT", ".grok\\sessions");
        let grok_active_sessions = env::var_os("AGENT_OBSERVER_GROK_ACTIVE_SESSIONS")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                grok_session_root
                    .parent()
                    .unwrap_or(&grok_session_root)
                    .join("active_sessions.json")
            });
        let grok_hook_root = local_app_data_path(
            "AGENT_OBSERVER_GROK_HOOK_ROOT",
            "agent-observer-poc\\grok-hooks",
        );
        let codex_exec_root = runtime_binding_root.join("codex-exec");
        runtime_monitor.refresh_from_disk(&runtime_binding_root);
        let mut snapshots = if options.watch {
            codex::discover_watch(
                &mut codex_watch,
                &codex_root,
                now,
                options.stale_after,
                options.include_stale,
            )
        } else {
            codex::discover(&codex_root, now, options.stale_after, options.include_stale)
        };
        snapshots.extend(claude::discover(
            &claude_root,
            now,
            options.stale_after,
            options.include_stale,
        ));
        snapshots.extend(claude_hook::discover(
            &claude_hook_root,
            now,
            options.stale_after,
            options.include_stale,
        ));
        snapshots.extend(codex_exec::discover(
            &codex_exec_root,
            now,
            options.stale_after,
            options.include_stale,
        ));
        let pi_rpc_root = runtime_binding_root.join("pi-rpc");
        snapshots.extend(pi_rpc::discover(
            &pi_rpc_root,
            now,
            options.stale_after,
            options.include_stale,
        ));
        snapshots.extend(pi::discover(
            &pi_session_root,
            &pi_hook_root,
            now,
            options.stale_after,
            options.include_stale,
        ));
        snapshots.extend(grok::discover(
            &grok_session_root,
            &grok_active_sessions,
            &grok_hook_root,
            now,
            options.stale_after,
            options.include_stale,
        ));
        let snapshots = filter_by_cwd(deduplicate(snapshots), options.cwd_filter.as_deref());
        let mut snapshots = if options.watch {
            watch_cache.refresh(snapshots, now, options.stale_after)
        } else {
            snapshots
        };
        for snapshot in &mut snapshots {
            snapshot.apply_evidence_freshness(now, options.stale_after);
        }
        host::apply_desktop_host_liveness(&mut snapshots, now);
        claude_desktop::apply_pid_registry(&claude_session_root, &mut snapshots, now);
        runtime_monitor.apply(&mut snapshots, now, runtime::observe_windows_process);
        if options.watch {
            watch_cache.store(&snapshots);
        }

        if let Some(recorder) = &mut recorder {
            if let Err(message) = recorder.record_changes(&snapshots, now) {
                eprintln!("{message}");
                std::process::exit(2);
            }
        }
        if options.json {
            print_json_scan(&snapshots, now, &codex_root, &claude_root);
        } else {
            print_snapshots(&snapshots, now, &codex_root, &claude_root);
        }

        if !options.watch {
            break;
        }
        thread::sleep(options.interval);
    }
}

fn run_doctor(json: bool) {
    let report = doctor::report(&doctor::DoctorOptions {
        codex_root: env_path("AGENT_OBSERVER_CODEX_ROOT", ".codex\\sessions"),
        claude_root: env_path("AGENT_OBSERVER_CLAUDE_ROOT", ".claude\\projects"),
        claude_session_root: env_path("AGENT_OBSERVER_CLAUDE_SESSION_ROOT", ".claude\\sessions"),
        claude_hook_root: local_app_data_path(
            "AGENT_OBSERVER_CLAUDE_HOOK_ROOT",
            "agent-observer-poc\\claude-hooks",
        ),
        pi_session_root: env_path("AGENT_OBSERVER_PI_SESSION_ROOT", ".pi\\agent\\sessions"),
        pi_hook_root: local_app_data_path(
            "AGENT_OBSERVER_PI_HOOK_ROOT",
            "agent-observer-poc\\pi-hooks",
        ),
        pi_bridge: env_path(
            "AGENT_OBSERVER_PI_BRIDGE",
            ".pi\\agent\\extensions\\agent-observer-bridge.ts",
        ),
        grok_session_root: env_path("AGENT_OBSERVER_GROK_SESSION_ROOT", ".grok\\sessions"),
        grok_hook_root: local_app_data_path(
            "AGENT_OBSERVER_GROK_HOOK_ROOT",
            "agent-observer-poc\\grok-hooks",
        ),
        grok_bridge: env_path(
            "AGENT_OBSERVER_GROK_BRIDGE",
            ".grok\\hooks\\agent-observer.json",
        ),
        runtime_binding_root: local_app_data_path(
            "AGENT_OBSERVER_RUNTIME_BINDING_ROOT",
            "agent-observer-poc\\runtime-bindings",
        ),
        codex_executable: executable_from_env("AGENT_OBSERVER_CODEX_EXE", "codex.exe"),
        claude_executable: executable_from_env("AGENT_OBSERVER_CLAUDE_EXE", "claude.exe"),
        pi_executable: env_or("AGENT_OBSERVER_PI_EXE", || {
            env::var_os("APPDATA")
                .map(PathBuf::from)
                .unwrap_or_default()
                .join("npm\\pi.cmd")
        }),
        grok_executable: env_or("AGENT_OBSERVER_GROK_EXE", || {
            env::var_os("USERPROFILE")
                .map(PathBuf::from)
                .unwrap_or_default()
                .join(".grok\\bin\\grok.exe")
        }),
    });
    if json {
        println!("{report}");
    } else {
        doctor::print_human(&report);
    }
}

fn env_path(variable: &str, home_relative: &str) -> PathBuf {
    if let Some(path) = env::var_os(variable) {
        return PathBuf::from(path);
    }
    env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join(home_relative)
}

fn env_or(variable: &str, fallback: impl FnOnce() -> PathBuf) -> PathBuf {
    env::var_os(variable)
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(fallback)
}

fn local_app_data_path(variable: &str, local_relative: &str) -> PathBuf {
    if let Some(path) = env::var_os(variable) {
        return PathBuf::from(path);
    }
    env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join(local_relative)
}

fn executable_from_env(variable: &str, fallback: &str) -> PathBuf {
    env::var_os(variable)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(fallback))
}

fn command_from_args(mut args: Vec<String>) -> Result<AppCommand, String> {
    let command = args.first().map(String::as_str);
    match command {
        Some("doctor") => {
            args.remove(0);
            let mut json = false;
            for argument in args {
                match argument.as_str() {
                    "--json" | "--jsonl" => json = true,
                    "--help" | "-h" => return Err("doctor help requested".to_string()),
                    _ => return Err(format!("unknown doctor argument: {argument}")),
                }
            }
            Ok(AppCommand::Doctor { json })
        }
        Some("run") => {
            args.remove(0);
            parse_run_command(args).map(AppCommand::Run)
        }
        Some("observe") => {
            args.remove(0);
            options_from_args(args, false).map(AppCommand::Observe)
        }
        Some("watch") => {
            args.remove(0);
            options_from_args(args, true).map(AppCommand::Observe)
        }
        Some(value) if !value.starts_with('-') => Err(format!("unknown command: {value}")),
        _ => options_from_args(args, false).map(AppCommand::Observe),
    }
}

fn options_from_args(args: Vec<String>, force_watch: bool) -> Result<Options, String> {
    let mut options = Options {
        watch: force_watch,
        json: false,
        include_stale: false,
        interval: Duration::from_secs(2),
        stale_after: Duration::from_secs(5 * 60),
        record_file: None,
        cwd_filter: None,
        runtime_binding_root: None,
    };
    let mut args = args.into_iter();
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--watch" => options.watch = true,
            "--json" | "--jsonl" => options.json = true,
            "--all" => options.include_stale = true,
            "--interval-secs" => {
                options.interval = duration_argument(&mut args, "--interval-secs")?
            }
            "--stale-after-secs" => {
                options.stale_after = duration_argument(&mut args, "--stale-after-secs")?
            }
            "--record-file" => {
                let path = args
                    .next()
                    .ok_or_else(|| "--record-file requires a path".to_string())?;
                options.record_file = Some(PathBuf::from(path));
            }
            "--cwd" => {
                let cwd = args
                    .next()
                    .ok_or_else(|| "--cwd requires an exact cwd".to_string())?;
                options.cwd_filter = Some(cwd);
            }
            "--runtime-binding-root" => {
                let path = args
                    .next()
                    .ok_or_else(|| "--runtime-binding-root requires a path".to_string())?;
                options.runtime_binding_root = Some(PathBuf::from(path));
            }
            _ => return Err(format!("unknown argument: {argument}")),
        }
    }
    Ok(options)
}

fn parse_run_command(args: Vec<String>) -> Result<runner::RunOptions, String> {
    let mut args = args.into_iter();
    let family = match args.next().as_deref() {
        Some("claude") => runner::RunFamily::Claude,
        Some("codex") => runner::RunFamily::Codex,
        Some("pi") => runner::RunFamily::Pi,
        Some(value) => return Err(format!("unknown run family: {value}")),
        None => return Err("run requires claude, codex or pi".to_string()),
    };
    if family == runner::RunFamily::Pi {
        parse_run_pi(args, family)
    } else {
        parse_run_cli(args, family)
    }
}

fn parse_run_cli(
    args: impl Iterator<Item = String>,
    family: runner::RunFamily,
) -> Result<runner::RunOptions, String> {
    let mut args = args;
    let mut cwd =
        env::current_dir().map_err(|error| format!("cannot read current cwd: {error}"))?;
    let mut executable = match family {
        runner::RunFamily::Claude => executable_from_env("AGENT_OBSERVER_CLAUDE_EXE", "claude.exe"),
        runner::RunFamily::Codex => executable_from_env("AGENT_OBSERVER_CODEX_EXE", "codex.exe"),
        runner::RunFamily::Pi => unreachable!("pi is parsed by parse_run_pi"),
    };
    let mut runtime_binding_root = local_app_data_path(
        "AGENT_OBSERVER_RUNTIME_BINDING_ROOT",
        "agent-observer-poc\\runtime-bindings",
    );
    let mut claude_hook_root = local_app_data_path(
        "AGENT_OBSERVER_CLAUDE_HOOK_ROOT",
        "agent-observer-poc\\claude-hooks",
    );
    let mut child_args = Vec::new();
    let mut child_mode = false;
    while let Some(argument) = args.next() {
        if child_mode {
            child_args.push(argument);
            continue;
        }
        match argument.as_str() {
            "--" => child_mode = true,
            "--cwd" => {
                cwd = PathBuf::from(
                    args.next()
                        .ok_or_else(|| "run --cwd requires a path".to_string())?,
                );
            }
            "--exe" => {
                executable = PathBuf::from(
                    args.next()
                        .ok_or_else(|| "run --exe requires a path".to_string())?,
                );
            }
            "--runtime-binding-root" => {
                runtime_binding_root = PathBuf::from(
                    args.next()
                        .ok_or_else(|| "run --runtime-binding-root requires a path".to_string())?,
                );
            }
            "--claude-hook-root" => {
                claude_hook_root = PathBuf::from(
                    args.next()
                        .ok_or_else(|| "run --claude-hook-root requires a path".to_string())?,
                );
            }
            _ => {
                return Err(format!(
                    "unknown run option before --: {argument}; put child arguments after --"
                ));
            }
        }
    }
    Ok(runner::RunOptions {
        family,
        cwd,
        executable,
        child_args,
        runtime_binding_root,
        claude_hook_root,
        pi: None,
    })
}

fn parse_run_pi(
    args: impl Iterator<Item = String>,
    family: runner::RunFamily,
) -> Result<runner::RunOptions, String> {
    let mut args = args;
    let mut cwd =
        env::current_dir().map_err(|error| format!("cannot read current cwd: {error}"))?;
    let mut runtime_binding_root = local_app_data_path(
        "AGENT_OBSERVER_RUNTIME_BINDING_ROOT",
        "agent-observer-poc\\runtime-bindings",
    );
    let mut node_executable = env_or("AGENT_OBSERVER_PI_NODE_EXE", || {
        PathBuf::from(r"C:\Program Files\nodejs\node.exe")
    });
    let mut pi_cli_js = env_or("AGENT_OBSERVER_PI_CLI_JS", || {
        env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_default()
            .join(r"npm\node_modules\@earendil-works\pi-coding-agent\dist\bundle\cli.js")
    });
    let mut session_dir = env::var_os("AGENT_OBSERVER_PI_RPC_SESSION_ROOT")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty());
    let mut provider = None;
    let mut model = None;
    let mut thinking = None;
    let mut name = "Pi Adapter PoC".to_string();
    let mut prompt = None;
    let mut child_mode = false;
    while let Some(argument) = args.next() {
        if child_mode {
            if prompt.is_some() {
                return Err(
                    "run pi accepts exactly one prompt after --; a second prompt was provided"
                        .to_string(),
                );
            }
            prompt = Some(argument);
            continue;
        }
        match argument.as_str() {
            "--" => child_mode = true,
            "--cwd" => {
                cwd = PathBuf::from(
                    args.next()
                        .ok_or_else(|| "run pi --cwd requires a path".to_string())?,
                );
            }
            "--runtime-binding-root" => {
                runtime_binding_root =
                    PathBuf::from(args.next().ok_or_else(|| {
                        "run pi --runtime-binding-root requires a path".to_string()
                    })?);
            }
            "--pi-node-exe" => {
                node_executable = PathBuf::from(
                    args.next()
                        .ok_or_else(|| "run pi --pi-node-exe requires a path".to_string())?,
                );
            }
            "--pi-cli-js" => {
                pi_cli_js = PathBuf::from(
                    args.next()
                        .ok_or_else(|| "run pi --pi-cli-js requires a path".to_string())?,
                );
            }
            "--pi-session-dir" => {
                session_dir =
                    Some(PathBuf::from(args.next().ok_or_else(|| {
                        "run pi --pi-session-dir requires a path".to_string()
                    })?));
            }
            "--provider" => {
                provider = Some(
                    args.next()
                        .ok_or_else(|| "run pi --provider requires a name".to_string())?,
                );
            }
            "--model" => {
                model = Some(
                    args.next()
                        .ok_or_else(|| "run pi --model requires an id".to_string())?,
                );
            }
            "--thinking" => {
                thinking = Some(
                    args.next()
                        .ok_or_else(|| "run pi --thinking requires a level".to_string())?,
                );
            }
            "--name" => {
                name = args
                    .next()
                    .ok_or_else(|| "run pi --name requires text".to_string())?;
            }
            _ => {
                return Err(format!(
                    "unknown run option before --: {argument}; run pi options are --cwd --runtime-binding-root --pi-node-exe --pi-cli-js --pi-session-dir --provider --model --thinking --name"
                ));
            }
        }
    }
    let session_dir = session_dir.ok_or_else(|| {
        "run pi requires --pi-session-dir or the AGENT_OBSERVER_PI_RPC_SESSION_ROOT environment variable".to_string()
    })?;
    let prompt =
        prompt.ok_or_else(|| "run pi requires -- followed by exactly one prompt".to_string())?;
    Ok(runner::RunOptions {
        family,
        cwd,
        executable: PathBuf::new(),
        child_args: Vec::new(),
        runtime_binding_root,
        claude_hook_root: PathBuf::new(),
        pi: Some(Box::new(runner::PiRunOptions {
            node_executable,
            pi_cli_js,
            session_dir,
            provider,
            model,
            thinking,
            name,
            prompt,
        })),
    })
}

fn print_usage() {
    println!("Agent Observer Console PoC");
    println!();
    println!("usage:");
    println!("  agent-observer-poc observe [OPTIONS]");
    println!("  agent-observer-poc watch [OPTIONS]");
    println!("  agent-observer-poc doctor [--json]");
    println!("  agent-observer-poc run claude [RUN OPTIONS] -- [CLAUDE ARGS]");
    println!("  agent-observer-poc run codex [RUN OPTIONS] -- [CODEX EXEC ARGS]");
    println!("  agent-observer-poc run pi [RUN OPTIONS] -- <ONE PROMPT>");
    println!();
    println!("observe/watch options:");
    println!("  --all --json --interval-secs N --stale-after-secs N --cwd PATH");
    println!("  --record-file PATH --runtime-binding-root PATH");
    println!();
    println!("run options (claude/codex):");
    println!("  --cwd PATH --exe PATH --runtime-binding-root PATH --claude-hook-root PATH");
    println!();
    println!("run pi options:");
    println!("  --cwd PATH --runtime-binding-root PATH --pi-node-exe PATH --pi-cli-js PATH");
    println!("  --pi-session-dir PATH --provider NAME --model ID --thinking LEVEL --name TEXT");
    println!("  then -- followed by exactly one prompt; the prompt is never persisted");
    println!();
    println!("run pi environment overrides:");
    println!("  AGENT_OBSERVER_PI_NODE_EXE AGENT_OBSERVER_PI_CLI_JS");
    println!("  AGENT_OBSERVER_PI_RPC_SESSION_ROOT (required unless --pi-session-dir is given)");
    println!();
    println!("Legacy flag-only invocation remains supported; --watch selects watch mode.");
}

fn duration_argument(
    args: &mut impl Iterator<Item = String>,
    name: &str,
) -> Result<Duration, String> {
    let value = args
        .next()
        .ok_or_else(|| format!("{name} requires an integer number of seconds"))?;
    let seconds = value
        .parse::<u64>()
        .map_err(|_| format!("{name} requires an integer number of seconds"))?;
    Ok(Duration::from_secs(seconds))
}

fn deduplicate(snapshots: Vec<SessionSnapshot>) -> Vec<SessionSnapshot> {
    let mut by_identity: BTreeMap<_, SessionSnapshot> = BTreeMap::new();
    for snapshot in snapshots {
        let key = (snapshot.family, snapshot.native_session_id.clone());
        if let Some(existing) = by_identity.get_mut(&key) {
            *existing = merge_snapshots(existing.clone(), snapshot);
        } else {
            by_identity.insert(key, snapshot);
        }
    }
    let mut snapshots = by_identity.into_values().collect::<Vec<_>>();
    snapshots.sort_by_key(|snapshot| std::cmp::Reverse(snapshot.last_source_activity_at));
    snapshots
}

fn filter_by_cwd(
    snapshots: Vec<SessionSnapshot>,
    cwd_filter: Option<&str>,
) -> Vec<SessionSnapshot> {
    let Some(cwd_filter) = cwd_filter else {
        return snapshots;
    };
    snapshots
        .into_iter()
        .filter(|snapshot| snapshot.cwd.as_deref() == Some(cwd_filter))
        .collect()
}

fn merge_snapshots(existing: SessionSnapshot, incoming: SessionSnapshot) -> SessionSnapshot {
    let incoming_source_is_newer =
        incoming.last_source_activity_at >= existing.last_source_activity_at;
    let mut merged = if incoming_source_is_newer {
        incoming.clone()
    } else {
        existing.clone()
    };

    if incoming_attention_wins(&existing, &incoming) {
        merged.attention_state = incoming.attention_state;
        merged.attention_evidence = incoming.attention_evidence.clone();
        merged.last_attention_evidence_at = incoming.last_attention_evidence_at;
    } else {
        merged.attention_state = existing.attention_state;
        merged.attention_evidence = existing.attention_evidence.clone();
        merged.last_attention_evidence_at = existing.last_attention_evidence_at;
    }
    if incoming_session_liveness_wins(&existing, &incoming) {
        merged.session_liveness = incoming.session_liveness;
        merged.session_liveness_evidence = incoming.session_liveness_evidence.clone();
        merged.last_session_liveness_evidence_at = incoming.last_session_liveness_evidence_at;
    } else {
        merged.session_liveness = existing.session_liveness;
        merged.session_liveness_evidence = existing.session_liveness_evidence.clone();
        merged.last_session_liveness_evidence_at = existing.last_session_liveness_evidence_at;
    }
    if incoming_host_liveness_wins(&existing, &incoming) {
        merged.host_liveness = incoming.host_liveness;
        merged.host_liveness_evidence = incoming.host_liveness_evidence.clone();
        merged.last_host_liveness_observed_at = incoming.last_host_liveness_observed_at;
    } else {
        merged.host_liveness = existing.host_liveness;
        merged.host_liveness_evidence = existing.host_liveness_evidence.clone();
        merged.last_host_liveness_observed_at = existing.last_host_liveness_observed_at;
    }

    merged.surface = merged_surface(&existing, &incoming, incoming_source_is_newer);
    merged.cwd = if incoming_source_is_newer {
        incoming.cwd.clone().or(existing.cwd.clone())
    } else {
        existing.cwd.clone().or(incoming.cwd.clone())
    };
    merged.session_display_name = if incoming_source_is_newer {
        incoming
            .session_display_name
            .clone()
            .or(existing.session_display_name.clone())
    } else {
        existing
            .session_display_name
            .clone()
            .or(incoming.session_display_name.clone())
    };
    merged.source = merged_source(&existing.source, &incoming.source);
    merged.last_source_activity_at = existing
        .last_source_activity_at
        .max(incoming.last_source_activity_at);
    merged.last_observed_at = existing.last_observed_at.max(incoming.last_observed_at);
    merged.runtime_binding_id = if incoming_source_is_newer {
        incoming
            .runtime_binding_id
            .clone()
            .or(existing.runtime_binding_id.clone())
    } else {
        existing
            .runtime_binding_id
            .clone()
            .or(incoming.runtime_binding_id.clone())
    };
    if incoming_session_liveness_wins(&existing, &incoming) {
        merged.active_runtime_id = incoming.active_runtime_id.clone();
    } else {
        merged.active_runtime_id = existing.active_runtime_id.clone();
    }
    merged.runtime_binding = incoming
        .runtime_binding
        .clone()
        .or_else(|| existing.runtime_binding.clone());
    merged
}

fn incoming_attention_wins(existing: &SessionSnapshot, incoming: &SessionSnapshot) -> bool {
    const SOURCE_SKEW: Duration = Duration::from_secs(5);
    match (
        existing.last_attention_evidence_at,
        incoming.last_attention_evidence_at,
    ) {
        (None, Some(_)) => return true,
        (Some(_), None) => return false,
        (None, None) => return attention_reliability(incoming) >= attention_reliability(existing),
        (Some(existing_at), Some(incoming_at)) => match incoming_at.duration_since(existing_at) {
            Ok(age) if age > SOURCE_SKEW => return true,
            Err(error) if error.duration() > SOURCE_SKEW => return false,
            _ => {}
        },
    }
    attention_reliability(incoming) >= attention_reliability(existing)
}

fn incoming_session_liveness_wins(existing: &SessionSnapshot, incoming: &SessionSnapshot) -> bool {
    if existing.session_liveness == SessionLiveness::Lost {
        return false;
    }
    if incoming.session_liveness == SessionLiveness::Lost {
        return true;
    }
    match (
        existing.last_session_liveness_evidence_at,
        incoming.last_session_liveness_evidence_at,
    ) {
        (None, Some(_)) => true,
        (Some(_), None) => false,
        (None, None) => false,
        (Some(existing_at), Some(incoming_at)) => incoming_at >= existing_at,
    }
}

fn incoming_host_liveness_wins(existing: &SessionSnapshot, incoming: &SessionSnapshot) -> bool {
    match (
        existing.last_host_liveness_observed_at,
        incoming.last_host_liveness_observed_at,
    ) {
        (None, Some(_)) => true,
        (Some(_), None) => false,
        (None, None) => false,
        (Some(existing_at), Some(incoming_at)) => incoming_at >= existing_at,
    }
}

fn attention_reliability(snapshot: &SessionSnapshot) -> u8 {
    if snapshot.attention_state == AttentionState::Unknown {
        return 0;
    }
    if is_hook(&snapshot.source)
        || snapshot
            .attention_evidence
            .starts_with("journal status/state:")
    {
        return 3;
    }
    if snapshot
        .attention_evidence
        .contains("user rejected a tool use")
    {
        return 2;
    }
    1
}

fn merged_surface(
    existing: &SessionSnapshot,
    incoming: &SessionSnapshot,
    incoming_source_is_newer: bool,
) -> model::Surface {
    if is_hook(&existing.source) && existing.surface != model::Surface::Unknown {
        return existing.surface;
    }
    if is_hook(&incoming.source) && incoming.surface != model::Surface::Unknown {
        return incoming.surface;
    }
    let preferred = if incoming_source_is_newer {
        incoming
    } else {
        existing
    };
    let fallback = if incoming_source_is_newer {
        existing
    } else {
        incoming
    };
    if preferred.surface != model::Surface::Unknown {
        preferred.surface
    } else {
        fallback.surface
    }
}

fn merged_source(existing: &str, incoming: &str) -> String {
    if existing == incoming {
        return existing.to_string();
    }

    let mut hook_sources = Vec::new();
    let mut other_sources = Vec::new();
    for source in existing.split(" + ").chain(incoming.split(" + ")) {
        let sources = if is_hook(source) {
            &mut hook_sources
        } else {
            &mut other_sources
        };
        if !sources.iter().any(|known| *known == source) {
            sources.push(source);
        }
    }
    hook_sources
        .into_iter()
        .chain(other_sources)
        .collect::<Vec<_>>()
        .join(" + ")
}

fn is_hook(source: &str) -> bool {
    source.starts_with("hook")
}

fn snapshot_json(snapshot: &SessionSnapshot, now: SystemTime) -> serde_json::Value {
    serde_json::json!({
        "agent_family": snapshot.family.to_string(),
        "surface": snapshot.surface.to_string(),
        "native_session_id": snapshot.native_session_id,
        "session_display_name": snapshot.session_display_name,
        "cwd": snapshot.cwd,
        "attention_state": snapshot.attention_state.to_string(),
        "attention_evidence": snapshot.attention_evidence,
        "evidence_freshness": snapshot.evidence_freshness.to_string(),
        "host_liveness": snapshot.host_liveness.to_string(),
        "host_liveness_evidence": snapshot.host_liveness_evidence,
        "session_liveness": snapshot.session_liveness.to_string(),
        "session_liveness_evidence": snapshot.session_liveness_evidence,
        "source": snapshot.source,
        "last_attention_evidence_unix_ms": optional_unix_millis(snapshot.last_attention_evidence_at),
        "last_session_liveness_evidence_unix_ms": optional_unix_millis(snapshot.last_session_liveness_evidence_at),
        "last_host_liveness_observed_unix_ms": optional_unix_millis(snapshot.last_host_liveness_observed_at),
        "last_source_activity_unix_ms": unix_millis(snapshot.last_source_activity_at),
        "last_observed_unix_ms": unix_millis(snapshot.last_observed_at),
        "attention_evidence_age_ms": snapshot.last_attention_evidence_at
            .and_then(|then| now.duration_since(then).ok())
            .map(|age| age.as_millis()),
        "runtime_binding_id": snapshot.runtime_binding_id,
        "active_runtime_id": snapshot.active_runtime_id,
        "process_id": snapshot.runtime_binding.as_ref().map(|binding| binding.process_id),
        "process_started_at_unix_ms": snapshot.runtime_binding
            .as_ref()
            .map(|binding| unix_millis(binding.process_started_at)),
        "host_instance_id": snapshot.runtime_binding
            .as_ref()
            .map(|binding| binding.host_instance_id.clone()),
    })
}

fn print_json_scan(
    snapshots: &[SessionSnapshot],
    now: SystemTime,
    codex_root: &std::path::Path,
    claude_root: &std::path::Path,
) {
    let sessions = snapshots
        .iter()
        .map(|snapshot| snapshot_json(snapshot, now))
        .collect::<Vec<_>>();
    println!(
        "{}",
        serde_json::json!({
            "observer_schema": 1,
            "record_type": "session_scan",
            "observed_at_unix_ms": unix_millis(now),
            "roots": {
                "codex_sessions": codex_root.to_string_lossy(),
                "claude_projects": claude_root.to_string_lossy(),
            },
            "session_count": sessions.len(),
            "sessions": sessions,
        })
    );
}

fn print_snapshots(
    snapshots: &[SessionSnapshot],
    now: SystemTime,
    codex_root: &std::path::Path,
    claude_root: &std::path::Path,
) {
    if snapshots.is_empty() {
        println!(
            "No recent sessions discovered. Codex root: {}; Claude root: {}",
            codex_root.display(),
            claude_root.display()
        );
        return;
    }
    for (index, snapshot) in snapshots.iter().enumerate() {
        if index > 0 {
            println!();
        }
        println!("{} {}", snapshot.family, snapshot.surface);
        println!("session: {}", snapshot.native_session_id);
        println!(
            "cwd: {}",
            snapshot.cwd.as_deref().unwrap_or("<unavailable>")
        );
        println!("attention: {}", snapshot.attention_state);
        println!("attention evidence: {}", snapshot.attention_evidence);
        println!("evidence freshness: {}", snapshot.evidence_freshness);
        println!("host liveness: {}", snapshot.host_liveness);
        if let Some(evidence) = &snapshot.host_liveness_evidence {
            println!("host evidence: {evidence}");
        }
        println!("session liveness: {}", snapshot.session_liveness);
        if let Some(evidence) = &snapshot.session_liveness_evidence {
            println!("session evidence: {evidence}");
        }
        println!("source: {}", snapshot.source);
        if let Some(runtime_binding_id) = &snapshot.runtime_binding_id {
            println!("runtime binding: {runtime_binding_id}");
        }
        if let Some(active_runtime_id) = &snapshot.active_runtime_id {
            println!("active runtime: {active_runtime_id}");
        }
        if let Some(binding) = &snapshot.runtime_binding {
            println!(
                "bound process: pid {} started {} ago",
                binding.process_id,
                age_text(now, Some(binding.process_started_at))
            );
        }
        println!(
            "attention seen: {} ago",
            age_text(now, snapshot.last_attention_evidence_at)
        );
        println!(
            "source activity: {} ago",
            age_text(now, Some(snapshot.last_source_activity_at))
        );
        println!("observed: just now");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AgentFamily, Surface};

    fn snapshot(
        now: SystemTime,
        attention: AttentionState,
        evidence: &str,
        source: &str,
        evidence_age: Duration,
    ) -> SessionSnapshot {
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Claude,
            if source.starts_with("hook") {
                Surface::Cli
            } else {
                Surface::Unknown
            },
            "shared-session".to_string(),
            Some("D:\\ProjectA".to_string()),
            source.to_string(),
            now - evidence_age,
        );
        snapshot.set_attention(attention, evidence, Some(now - evidence_age));
        snapshot
    }

    #[test]
    fn hook_attention_wins_over_nearby_journal_heuristic() {
        let now = SystemTime::now();
        let hook = snapshot(
            now,
            AttentionState::NeedsMe,
            "hook: Claude needs user attention",
            "hook (surface: CLI)",
            Duration::from_secs(2),
        );
        let journal = snapshot(
            now,
            AttentionState::Working,
            "heuristic: latest user journal record awaits agent work",
            "journal (entrypoint: cli)",
            Duration::from_secs(1),
        );

        let merged = deduplicate(vec![hook, journal]);

        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].attention_state, AttentionState::NeedsMe);
        assert!(
            merged[0]
                .source
                .starts_with("hook (surface: CLI) + journal")
        );
    }

    #[test]
    fn merge_keeps_journal_display_name_without_changing_attention() {
        let now = SystemTime::now();
        let hook = snapshot(
            now,
            AttentionState::NeedsMe,
            "hook: Claude needs user attention",
            "hook (surface: CLI)",
            Duration::from_secs(2),
        );
        let mut journal = snapshot(
            now,
            AttentionState::Working,
            "heuristic: latest user journal record awaits agent work",
            "journal (entrypoint: cli)",
            Duration::from_secs(1),
        );
        journal.session_display_name = Some("Review trading annotations".to_string());

        let merged = deduplicate(vec![hook, journal]);

        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].attention_state, AttentionState::NeedsMe);
        assert_eq!(
            merged[0].session_display_name.as_deref(),
            Some("Review trading annotations")
        );
        assert_eq!(merged[0].native_session_id, "shared-session");
    }

    #[test]
    fn later_journal_rejection_replaces_an_older_hook_attention() {
        let now = SystemTime::now();
        let hook = snapshot(
            now,
            AttentionState::Working,
            "hook: Claude is processing work",
            "hook (surface: CLI)",
            Duration::from_secs(20),
        );
        let journal = snapshot(
            now,
            AttentionState::NeedsMe,
            "heuristic: user rejected a tool use; agent awaits next instruction",
            "journal (entrypoint: cli)",
            Duration::from_secs(1),
        );

        let merged = deduplicate(vec![hook, journal]);

        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].attention_state, AttentionState::NeedsMe);
        assert!(merged[0].attention_evidence.contains("rejected a tool use"));
        assert_eq!(merged[0].surface, Surface::Cli);
    }

    #[test]
    fn watcher_retains_a_missing_working_session_with_stale_freshness() {
        let now = SystemTime::now();
        let mut cache = SnapshotCache::default();
        let working = snapshot(
            now,
            AttentionState::Working,
            "event_msg.task_started",
            "journal",
            Duration::ZERO,
        );

        let first = cache.refresh(vec![working], now, Duration::from_secs(5));
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].attention_state, AttentionState::Working);

        let stale = cache.refresh(
            Vec::new(),
            now + Duration::from_secs(6),
            Duration::from_secs(5),
        );
        assert_eq!(stale.len(), 1);
        assert_eq!(stale[0].attention_state, AttentionState::Working);
        assert_eq!(stale[0].evidence_freshness, EvidenceFreshness::Stale);
        assert_eq!(stale[0].native_session_id, "shared-session");
    }

    #[test]
    fn cache_does_not_duplicate_a_repeated_source_label() {
        assert_eq!(
            merged_source(
                "hook (surface: CLI) + journal (entrypoint: cli)",
                "journal (entrypoint: cli)"
            ),
            "hook (surface: CLI) + journal (entrypoint: cli)"
        );
    }

    #[test]
    fn recorder_writes_freshness_changes_without_rewriting_attention() {
        let now = SystemTime::now();
        let path = env::temp_dir().join(format!(
            "agent-observer-recorder-test-{}.jsonl",
            unix_millis(now)
        ));
        let mut recorder = SnapshotRecorder::new(path.clone(), now).unwrap();
        let mut working = snapshot(
            now,
            AttentionState::Working,
            "event_msg.task_started",
            "journal",
            Duration::ZERO,
        );
        working.apply_evidence_freshness(now, Duration::from_secs(5));

        recorder.record_changes(&[working.clone()], now).unwrap();
        recorder.record_changes(&[working.clone()], now).unwrap();

        let mut stale = working;
        stale.apply_evidence_freshness(now + Duration::from_secs(6), Duration::from_secs(5));
        recorder
            .record_changes(&[stale], now + Duration::from_secs(6))
            .unwrap();

        let records = std::fs::read_to_string(&path).unwrap();
        assert_eq!(records.lines().count(), 3);
        assert!(records.contains("\"attention_state\":\"WORKING\""));
        assert!(records.contains("\"evidence_freshness\":\"STALE\""));
        assert!(!records.contains("\"attention_state\":\"STALE\""));
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn deduplicate_keeps_same_cwd_sessions_separate_by_native_id() {
        let now = SystemTime::now();
        let mut old = snapshot(
            now,
            AttentionState::Working,
            "task_started",
            "journal",
            Duration::ZERO,
        );
        old.native_session_id = "session-old".to_string();
        old.cwd = Some("D:\\agent-observer-runtime-binding-v1".to_string());
        let mut new = old.clone();
        new.native_session_id = "session-new".to_string();

        let merged = deduplicate(vec![old, new]);
        assert_eq!(merged.len(), 2);
        let ids = merged
            .iter()
            .map(|snapshot| snapshot.native_session_id.as_str())
            .collect::<Vec<_>>();
        assert!(ids.contains(&"session-old"));
        assert!(ids.contains(&"session-new"));
    }

    #[test]
    fn cwd_filter_keeps_only_the_disposable_workspace() {
        let now = SystemTime::now();
        let mut disposable = snapshot(
            now,
            AttentionState::Working,
            "task_started",
            "journal",
            Duration::ZERO,
        );
        disposable.cwd = Some("D:\\agent-observer-crash-test".to_string());
        let mut control = disposable.clone();
        control.cwd = Some("D:\\synthetic-workspace".to_string());

        let filtered = filter_by_cwd(
            vec![disposable, control],
            Some("D:\\agent-observer-crash-test"),
        );
        assert_eq!(filtered.len(), 1);
        assert_eq!(
            filtered[0].cwd.as_deref(),
            Some("D:\\agent-observer-crash-test")
        );
    }

    #[test]
    fn legacy_and_named_watch_commands_parse_to_the_same_mode() {
        let legacy = command_from_args(vec!["--watch".to_string(), "--json".to_string()])
            .expect("legacy watch");
        let named = command_from_args(vec!["watch".to_string(), "--jsonl".to_string()])
            .expect("named watch");

        for command in [legacy, named] {
            let AppCommand::Observe(options) = command else {
                panic!("expected observe command");
            };
            assert!(options.watch);
            assert!(options.json);
        }
    }

    #[test]
    fn run_command_keeps_observer_options_separate_from_child_arguments() {
        let command = command_from_args(vec![
            "run".to_string(),
            "codex".to_string(),
            "--cwd".to_string(),
            "D:\\disposable".to_string(),
            "--runtime-binding-root".to_string(),
            "D:\\bindings".to_string(),
            "--".to_string(),
            "exec".to_string(),
            "Reply with OK".to_string(),
        ])
        .expect("run command");

        let AppCommand::Run(options) = command else {
            panic!("expected run command");
        };
        assert_eq!(options.family, runner::RunFamily::Codex);
        assert_eq!(options.cwd, PathBuf::from("D:\\disposable"));
        assert_eq!(options.runtime_binding_root, PathBuf::from("D:\\bindings"));
        assert_eq!(options.child_args, ["exec", "Reply with OK"]);
    }

    fn run_pi_options(session_dir: &str, prompt: &str) -> Vec<String> {
        vec![
            "run".to_string(),
            "pi".to_string(),
            "--cwd".to_string(),
            "D:\\pi-workspace".to_string(),
            "--runtime-binding-root".to_string(),
            "D:\\pi-bindings".to_string(),
            "--pi-node-exe".to_string(),
            "C:\\node.exe".to_string(),
            "--pi-cli-js".to_string(),
            "C:\\cli.js".to_string(),
            "--pi-session-dir".to_string(),
            session_dir.to_string(),
            "--provider".to_string(),
            "xai".to_string(),
            "--model".to_string(),
            "xai/grok-4.3".to_string(),
            "--thinking".to_string(),
            "off".to_string(),
            "--name".to_string(),
            "Pi并行会话A_日本語".to_string(),
            "--".to_string(),
            prompt.to_string(),
        ]
    }

    #[test]
    fn run_pi_parses_options_and_a_single_prompt() {
        let command =
            command_from_args(run_pi_options("D:\\pi-sessions", "Reply with PI_RPC_OK")).unwrap();
        let AppCommand::Run(options) = command else {
            panic!("expected run command");
        };
        assert_eq!(options.family, runner::RunFamily::Pi);
        assert_eq!(options.cwd, PathBuf::from("D:\\pi-workspace"));
        assert_eq!(
            options.runtime_binding_root,
            PathBuf::from("D:\\pi-bindings")
        );
        let pi = options.pi.expect("pi options");
        assert_eq!(pi.node_executable, PathBuf::from("C:\\node.exe"));
        assert_eq!(pi.pi_cli_js, PathBuf::from("C:\\cli.js"));
        assert_eq!(pi.session_dir, PathBuf::from("D:\\pi-sessions"));
        assert_eq!(pi.provider.as_deref(), Some("xai"));
        assert_eq!(pi.model.as_deref(), Some("xai/grok-4.3"));
        assert_eq!(pi.thinking.as_deref(), Some("off"));
        assert_eq!(pi.name, "Pi并行会话A_日本語");
        assert_eq!(pi.prompt, "Reply with PI_RPC_OK");
        assert!(options.child_args.is_empty());
    }

    #[test]
    fn run_pi_rejects_zero_or_two_prompts() {
        let no_prompt = command_from_args(vec![
            "run".to_string(),
            "pi".to_string(),
            "--pi-session-dir".to_string(),
            "D:\\s".to_string(),
        ]);
        assert!(matches!(no_prompt, Err(ref message) if message.contains("exactly one prompt")));

        let two_prompts = command_from_args(vec![
            "run".to_string(),
            "pi".to_string(),
            "--pi-session-dir".to_string(),
            "D:\\s".to_string(),
            "--".to_string(),
            "first".to_string(),
            "second".to_string(),
        ]);
        assert!(matches!(two_prompts, Err(ref message) if message.contains("second prompt")));
    }

    #[test]
    fn run_pi_requires_a_dedicated_session_dir() {
        let parsed = command_from_args(vec![
            "run".to_string(),
            "pi".to_string(),
            "--".to_string(),
            "hello".to_string(),
        ]);
        assert!(matches!(
            parsed,
            Err(ref message) if message.contains("--pi-session-dir")
        ));
    }

    #[test]
    fn deduplicate_keeps_agent_families_separate_for_identical_native_ids() {
        let now = SystemTime::now();
        let shared_id = "uuid-identical".to_string();
        let mut pi = snapshot(
            now,
            AttentionState::Working,
            "task_started",
            "journal",
            Duration::ZERO,
        );
        pi.family = AgentFamily::Pi;
        pi.surface = Surface::Cli;
        pi.native_session_id = shared_id.clone();
        let mut codex = pi.clone();
        codex.family = AgentFamily::Codex;
        let mut claude = pi.clone();
        claude.family = AgentFamily::Claude;
        let mut grok = pi.clone();
        grok.family = AgentFamily::Grok;

        let merged = deduplicate(vec![pi, codex, claude, grok]);

        assert_eq!(merged.len(), 4);
        let families = merged
            .iter()
            .map(|snapshot| snapshot.family)
            .collect::<Vec<_>>();
        assert!(families.contains(&AgentFamily::Pi));
        assert!(families.contains(&AgentFamily::Codex));
        assert!(families.contains(&AgentFamily::Claude));
        assert!(families.contains(&AgentFamily::Grok));
        assert_eq!(merged[0].native_session_id, shared_id);
    }

    #[test]
    fn json_snapshot_exposes_all_four_independent_dimensions() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(100);
        let mut value = snapshot(
            now,
            AttentionState::Working,
            "task_started",
            "journal",
            Duration::from_secs(10),
        );
        value.apply_evidence_freshness(now, Duration::from_secs(5));
        value.set_host_liveness(HostLiveness::Unknown, "no exact host", now);
        value.set_session_liveness(SessionLiveness::Unknown, "no exact binding", Some(now));

        let json = snapshot_json(&value, now);
        assert_eq!(json["attention_state"], "WORKING");
        assert_eq!(json["evidence_freshness"], "STALE");
        assert_eq!(json["host_liveness"], "UNKNOWN");
        assert_eq!(json["session_liveness"], "UNKNOWN");
        assert_eq!(json["session_display_name"], serde_json::Value::Null);

        value.session_display_name = Some("Fix quota reset jitter".to_string());
        let named = snapshot_json(&value, now);
        assert_eq!(named["session_display_name"], "Fix quota reset jitter");
        assert_eq!(named["attention_state"], "WORKING");
        assert_eq!(named["native_session_id"], "shared-session");
    }
}
