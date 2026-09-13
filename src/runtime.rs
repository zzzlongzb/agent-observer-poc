use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde_json::Value;

use crate::model::{
    AgentFamily, AttentionState, HostLiveness, RuntimeBinding, SessionLiveness, SessionSnapshot,
    Surface, system_time_from_unix_millis, unix_millis,
};
use crate::process::{ProcessObservation, observe_expected};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchRecord {
    pub path: PathBuf,
    pub runtime_binding_id: String,
    pub family: AgentFamily,
    pub native_session_id: Option<String>,
    pub active_runtime_id: Option<String>,
    pub host_instance_id: String,
    pub process_id: u32,
    pub process_started_at: SystemTime,
    pub cwd: Option<String>,
    pub launched_at: SystemTime,
    pub binding_source: String,
    pub abnormal_exit_observed_at: Option<SystemTime>,
}

impl LaunchRecord {
    pub fn new(
        path: PathBuf,
        runtime_binding_id: String,
        family: AgentFamily,
        process_id: u32,
        process_started_at: SystemTime,
        cwd: Option<String>,
        launched_at: SystemTime,
        binding_source: impl Into<String>,
    ) -> Self {
        Self {
            path,
            runtime_binding_id,
            family,
            native_session_id: None,
            active_runtime_id: None,
            host_instance_id: host_instance_id(process_id, process_started_at),
            process_id,
            process_started_at,
            cwd,
            launched_at,
            binding_source: binding_source.into(),
            abnormal_exit_observed_at: None,
        }
    }

    pub fn persist(&self) -> Result<(), String> {
        persist_launch_record(self)
    }

    pub fn exact_binding(&self, observed_at: SystemTime) -> Option<RuntimeBinding> {
        let native_session_id = self.native_session_id.clone()?;
        let active_runtime_id = self.active_runtime_id.clone()?;
        if native_session_id.is_empty() || active_runtime_id.is_empty() {
            return None;
        }
        let binding = RuntimeBinding {
            runtime_binding_id: self.runtime_binding_id.clone(),
            native_session_id,
            active_runtime_id,
            host_instance_id: self.host_instance_id.clone(),
            process_id: self.process_id,
            process_started_at: self.process_started_at,
            active_observed_at: observed_at,
        };
        binding.is_exact_active().then_some(binding)
    }

    fn has_terminal_abnormal_exit(&self) -> bool {
        self.abnormal_exit_observed_at.is_some()
    }
}

pub struct RuntimeMonitor {
    pub instance_id: String,
    records: Vec<LaunchRecord>,
    seen_alive: BTreeSet<String>,
}

impl RuntimeMonitor {
    pub fn load(root: &Path, instance_id: impl Into<String>) -> Self {
        let mut records = Vec::new();
        load_launch_records(root, &mut records);
        Self {
            instance_id: instance_id.into(),
            records,
            seen_alive: BTreeSet::new(),
        }
    }

    #[allow(dead_code)]
    pub fn from_records(instance_id: impl Into<String>, records: Vec<LaunchRecord>) -> Self {
        Self {
            instance_id: instance_id.into(),
            records,
            seen_alive: BTreeSet::new(),
        }
    }

    pub fn refresh_from_disk(&mut self, root: &Path) {
        let previous = self
            .records
            .iter()
            .map(|record| (record.runtime_binding_id.clone(), record.clone()))
            .collect::<BTreeMap<_, _>>();
        let mut records = Vec::new();
        load_launch_records(root, &mut records);
        for record in &mut records {
            let Some(old) = previous.get(&record.runtime_binding_id) else {
                continue;
            };
            if record.abnormal_exit_observed_at.is_none() {
                record.abnormal_exit_observed_at = old.abnormal_exit_observed_at;
            }
            if record.native_session_id.is_none() {
                record.native_session_id = old.native_session_id.clone();
            }
            if record.active_runtime_id.is_none() {
                record.active_runtime_id = old.active_runtime_id.clone();
            }
        }
        self.records = records;
    }

    pub fn apply(
        &mut self,
        snapshots: &mut [SessionSnapshot],
        now: SystemTime,
        mut observe: impl FnMut(u32, SystemTime) -> ProcessObservation,
    ) {
        for snapshot in snapshots.iter_mut() {
            let Some(index) = find_record_index(&self.records, snapshot) else {
                continue;
            };
            absorb_snapshot_identity(&mut self.records[index], snapshot);
            let _ = persist_launch_record(&self.records[index]);

            if let Some(native_session_id) = self.records[index].native_session_id.clone() {
                let binding = RuntimeBinding {
                    runtime_binding_id: self.records[index].runtime_binding_id.clone(),
                    native_session_id,
                    active_runtime_id: self.records[index]
                        .active_runtime_id
                        .clone()
                        .unwrap_or_default(),
                    host_instance_id: self.records[index].host_instance_id.clone(),
                    process_id: self.records[index].process_id,
                    process_started_at: self.records[index].process_started_at,
                    active_observed_at: now,
                };
                let _ = snapshot.bind_runtime(binding);
            } else if snapshot.runtime_binding.is_none() {
                snapshot.runtime_binding_id = Some(self.records[index].runtime_binding_id.clone())
                    .filter(|value| !value.is_empty())
                    .or(snapshot.runtime_binding_id.clone());
            }

            let observation = observe(
                self.records[index].process_id,
                self.records[index].process_started_at,
            );
            apply_observation(
                snapshot,
                &mut self.records[index],
                &self.instance_id,
                &mut self.seen_alive,
                observation,
                now,
            );
            let _ = persist_launch_record(&self.records[index]);
        }
    }
}

pub fn observe_windows_process(
    process_id: u32,
    expected_started_at: SystemTime,
) -> ProcessObservation {
    observe_expected(process_id, expected_started_at)
}

fn load_launch_records(root: &Path, records: &mut Vec<LaunchRecord>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("json") {
            continue;
        }
        if let Some(record) = parse_launch_record(&path) {
            records.push(record);
        }
    }
}

fn parse_launch_record(path: &Path) -> Option<LaunchRecord> {
    let text = fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    if value.get("record_type").and_then(Value::as_str) != Some("cli_runtime_launch") {
        return None;
    }
    let runtime_binding_id = nonempty_string(&value, "runtime_binding_id")?;
    let family = match value.get("family").and_then(Value::as_str)? {
        "Claude" => AgentFamily::Claude,
        "Codex" => AgentFamily::Codex,
        "Pi" => AgentFamily::Pi,
        "Grok" => AgentFamily::Grok,
        _ => return None,
    };
    let process_id = value.get("process_id").and_then(Value::as_u64)? as u32;
    let process_started_at = system_time_from_unix_millis(
        value
            .get("process_started_at_unix_ms")
            .and_then(json_u128)?,
    )?;
    let launched_at =
        system_time_from_unix_millis(value.get("launched_at_unix_ms").and_then(json_u128)?)?;
    Some(LaunchRecord {
        path: path.to_path_buf(),
        runtime_binding_id,
        family,
        native_session_id: nonempty_string(&value, "native_session_id"),
        active_runtime_id: nonempty_string(&value, "active_runtime_id"),
        host_instance_id: nonempty_string(&value, "host_instance_id")?,
        process_id,
        process_started_at,
        cwd: nonempty_string(&value, "cwd"),
        launched_at,
        binding_source: nonempty_string(&value, "binding_source")
            .unwrap_or_else(|| "unknown".to_string()),
        abnormal_exit_observed_at: value
            .get("abnormal_exit_observed_at_unix_ms")
            .and_then(json_u128)
            .and_then(system_time_from_unix_millis),
    })
}

fn persist_launch_record(record: &LaunchRecord) -> Result<(), String> {
    if record.path.as_os_str().is_empty() {
        return Ok(());
    }
    if let Some(parent) = record.path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let value = serde_json::json!({
        "observer_schema": 2,
        "record_type": "cli_runtime_launch",
        "runtime_binding_id": record.runtime_binding_id,
        "family": record.family.to_string(),
        "surface": Surface::Cli.to_string(),
        "cwd": record.cwd,
        "process_id": record.process_id,
        "process_started_at_unix_ms": unix_millis(record.process_started_at),
        "host_instance_id": record.host_instance_id,
        "launched_at_unix_ms": unix_millis(record.launched_at),
        "native_session_id": record.native_session_id,
        "active_runtime_id": record.active_runtime_id,
        "binding_source": record.binding_source,
        "abnormal_exit_observed_at_unix_ms": record
            .abnormal_exit_observed_at
            .map(unix_millis),
    });
    fs::write(&record.path, format!("{value}\n")).map_err(|error| error.to_string())
}

fn json_u128(value: &Value) -> Option<u128> {
    value
        .as_u64()
        .map(u128::from)
        .or_else(|| value.as_i64().and_then(|value| u128::try_from(value).ok()))
        .or_else(|| {
            value.as_f64().and_then(|value| {
                if value.is_finite() && value >= 0.0 {
                    Some(value as u128)
                } else {
                    None
                }
            })
        })
        .or_else(|| value.as_str()?.parse().ok())
}

fn nonempty_string(value: &Value, field: &str) -> Option<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn find_record_index(records: &[LaunchRecord], snapshot: &SessionSnapshot) -> Option<usize> {
    if let Some(runtime_binding_id) = snapshot
        .runtime_binding_id
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        let matches = records
            .iter()
            .enumerate()
            .filter(|(_, record)| {
                record.family == snapshot.family && record.runtime_binding_id == runtime_binding_id
            })
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        if matches.len() == 1 {
            return Some(matches[0]);
        }
        return None;
    }

    let matches = records
        .iter()
        .enumerate()
        .filter(|(_, record)| {
            record.family == snapshot.family
                && record
                    .native_session_id
                    .as_deref()
                    .is_some_and(|native_id| native_id == snapshot.native_session_id)
        })
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    if matches.len() == 1 {
        Some(matches[0])
    } else {
        None
    }
}

fn absorb_snapshot_identity(record: &mut LaunchRecord, snapshot: &SessionSnapshot) {
    if record.native_session_id.is_none() && !snapshot.native_session_id.is_empty() {
        record.native_session_id = Some(snapshot.native_session_id.clone());
    }
    if record.active_runtime_id.is_none() {
        if let Some(active_runtime_id) = snapshot
            .active_runtime_id
            .as_deref()
            .filter(|value| !value.is_empty())
        {
            record.active_runtime_id = Some(active_runtime_id.to_string());
        }
    } else if snapshot.active_runtime_id.is_none() && has_terminal_lifecycle(snapshot) {
        record.active_runtime_id = None;
    }
    if record.cwd.is_none() {
        record.cwd = snapshot.cwd.clone();
    }
}

fn apply_observation(
    snapshot: &mut SessionSnapshot,
    record: &mut LaunchRecord,
    observer_instance_id: &str,
    seen_alive: &mut BTreeSet<String>,
    observation: ProcessObservation,
    now: SystemTime,
) {
    match observation {
        ProcessObservation::Alive => {
            seen_alive.insert(record.runtime_binding_id.clone());
            snapshot.set_host_liveness(
                HostLiveness::Alive,
                format!(
                    "exact CLI runtime PID {} + creation time still running",
                    record.process_id
                ),
                now,
            );
        }
        ProcessObservation::Unreachable(message) => {
            snapshot.set_host_liveness(
                HostLiveness::Unreachable,
                format!("exact CLI runtime process query failed: {message}"),
                now,
            );
        }
        ProcessObservation::Missing | ProcessObservation::CreationTimeMismatch { .. } => {
            handle_absent_process(
                snapshot,
                record,
                observer_instance_id,
                seen_alive,
                &observation,
                now,
            );
        }
    }
}

fn handle_absent_process(
    snapshot: &mut SessionSnapshot,
    record: &mut LaunchRecord,
    observer_instance_id: &str,
    seen_alive: &BTreeSet<String>,
    observation: &ProcessObservation,
    now: SystemTime,
) {
    let pid_reuse = matches!(observation, ProcessObservation::CreationTimeMismatch { .. });
    let evidence = if pid_reuse {
        format!(
            "PID {} exists but process creation time does not match the launch record",
            record.process_id
        )
    } else {
        format!(
            "exact CLI runtime PID {} + creation time is not running",
            record.process_id
        )
    };

    if has_terminal_lifecycle(snapshot) {
        snapshot.set_host_liveness(HostLiveness::Dead, evidence, now);
        return;
    }

    let watched_alive = seen_alive.contains(&record.runtime_binding_id);
    if let Some(binding) = record.exact_binding(now) {
        if watched_alive || record.has_terminal_abnormal_exit() {
            if watched_alive && record.abnormal_exit_observed_at.is_none() {
                record.abnormal_exit_observed_at = Some(now);
            }
            snapshot.set_host_liveness(
                HostLiveness::Dead,
                format!("{evidence}; observer {observer_instance_id} watched this exact runtime"),
                now,
            );
            if let Some(exit) = binding.to_abnormal_exit(now) {
                let _ = snapshot.mark_lost_from_abnormal_bound_exit(&exit);
            }
            return;
        }
    }

    snapshot.set_host_liveness(
        HostLiveness::Unknown,
        format!("{evidence}; Observer instance {observer_instance_id} did not observe the exit"),
        now,
    );
    if snapshot.session_liveness != SessionLiveness::Lost {
        snapshot.set_session_liveness(
            SessionLiveness::Unknown,
            "Observer was not watching when the bound process disappeared; exit cause is unknown",
            Some(now),
        );
    }
}

fn has_terminal_lifecycle(snapshot: &SessionSnapshot) -> bool {
    snapshot.session_liveness == SessionLiveness::Detached
        || snapshot.attention_state == AttentionState::ResultReady
        || (snapshot.attention_state == AttentionState::Interrupted
            && snapshot.session_liveness == SessionLiveness::LiveIdle
            && snapshot.active_runtime_id.is_none())
}

pub fn host_instance_id(process_id: u32, process_started_at: SystemTime) -> String {
    let host = std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "unknown-host".to_string());
    format!(
        "{host}:pid:{process_id}:started:{}",
        unix_millis(process_started_at)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AbnormalRuntimeExit, AttentionState, EvidenceFreshness};
    use std::time::Duration;

    fn now() -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000)
    }

    fn claude_snapshot(native_id: &str, cwd: &str, at: SystemTime) -> SessionSnapshot {
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Claude,
            Surface::Cli,
            native_id.to_string(),
            Some(cwd.to_string()),
            "hook (surface: CLI)".to_string(),
            at,
        );
        snapshot.runtime_binding_id = Some("binding-1".to_string());
        snapshot.active_runtime_id = Some("prompt-1".to_string());
        snapshot.set_attention(
            AttentionState::Working,
            "hook: Claude is processing work",
            Some(at),
        );
        snapshot.set_session_liveness(
            SessionLiveness::LiveActive,
            "hook: active Claude prompt or tool lifecycle event",
            Some(at),
        );
        snapshot
    }

    fn launch_record(at: SystemTime) -> LaunchRecord {
        LaunchRecord {
            path: PathBuf::new(),
            runtime_binding_id: "binding-1".to_string(),
            family: AgentFamily::Claude,
            native_session_id: Some("session-1".to_string()),
            active_runtime_id: Some("prompt-1".to_string()),
            host_instance_id: "host:pid:10:started:1".to_string(),
            process_id: 10,
            process_started_at: at - Duration::from_secs(5),
            cwd: Some("D:\\agent-observer-runtime-binding-v1".to_string()),
            launched_at: at - Duration::from_secs(5),
            binding_source: "claude-hook".to_string(),
            abnormal_exit_observed_at: None,
        }
    }

    fn apply_with(
        record: LaunchRecord,
        snapshots: &mut [SessionSnapshot],
        at: SystemTime,
        observation: ProcessObservation,
    ) -> RuntimeMonitor {
        let mut monitor = RuntimeMonitor::from_records("observer-1", vec![record]);
        monitor.apply(snapshots, at, {
            let observation = observation.clone();
            move |_, _| observation.clone()
        });
        monitor
    }

    #[test]
    fn launch_record_json_round_trip_preserves_pid_and_creation_time() {
        let at = now();
        let dir = std::env::temp_dir().join(format!(
            "agent-observer-binding-parse-{}",
            unix_millis(SystemTime::now())
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("binding-1.json");
        let started_ms = unix_millis(at - Duration::from_secs(5));
        fs::write(
            &path,
            format!(
                r#"{{"observer_schema":2,"record_type":"cli_runtime_launch","runtime_binding_id":"binding-1","family":"Claude","surface":"CLI","cwd":"D:\\ws","process_id":63788,"process_started_at_unix_ms":{started_ms},"host_instance_id":"host:pid:63788:started:{started_ms}","launched_at_unix_ms":{started_ms},"native_session_id":"session-1","active_runtime_id":null,"binding_source":"claude-hook","abnormal_exit_observed_at_unix_ms":null,"harness_name":"A-normal"}}"#
            ),
        )
        .unwrap();

        let monitor = RuntimeMonitor::load(&dir, "observer-test");
        let mut snapshot = claude_snapshot("session-1", "D:\\ws", at);
        snapshot.active_runtime_id = None;
        snapshot.set_attention(
            AttentionState::ResultReady,
            "hook: Claude Stop reported no background work",
            Some(at),
        );
        snapshot.set_session_liveness(
            SessionLiveness::Detached,
            "hook: Claude SessionEnd detached the current runtime",
            Some(at),
        );
        let mut snapshots = vec![snapshot];
        let mut monitor = monitor;
        monitor.apply(&mut snapshots, at, |_, _| ProcessObservation::Missing);

        assert_eq!(
            snapshots[0].runtime_binding_id.as_deref(),
            Some("binding-1")
        );
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Detached);
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn host_instance_id_includes_pid_and_creation_time() {
        let at = now();
        let id = host_instance_id(10, at);
        assert!(id.contains("pid:10"));
        assert!(id.contains(&unix_millis(at).to_string()));
    }

    #[test]
    fn exact_binding_fields_all_match_before_lost() {
        let at = now();
        let record = launch_record(at);
        let binding = record.exact_binding(at).unwrap();
        assert!(binding.is_exact_active());
        let exit = binding.to_abnormal_exit(at).unwrap();
        assert!(binding.matches_abnormal_exit(&exit));
        assert_eq!(binding.runtime_binding_id, "binding-1");
        assert_eq!(binding.native_session_id, "session-1");
        assert_eq!(binding.active_runtime_id, "prompt-1");
        assert_eq!(binding.process_id, 10);
        assert_eq!(binding.process_started_at, record.process_started_at);
        assert_eq!(binding.host_instance_id, record.host_instance_id);
    }

    #[test]
    fn runtime_binding_id_mismatch_never_attaches_or_marks_lost() {
        let at = now();
        let mut snapshot = claude_snapshot("session-1", "D:\\ws", at);
        snapshot.runtime_binding_id = Some("binding-other".to_string());
        let mut snapshots = vec![snapshot];
        apply_with(
            launch_record(at),
            &mut snapshots,
            at,
            ProcessObservation::Missing,
        );

        assert!(snapshots[0].runtime_binding.is_none());
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn pid_reuse_with_new_creation_time_is_not_our_process() {
        let at = now();
        let record = launch_record(at);
        let expected_started_at = record.process_started_at;
        let mut snapshots = vec![claude_snapshot("session-1", "D:\\ws", at)];
        let mut monitor = RuntimeMonitor::from_records("observer-1", vec![record]);
        monitor.apply(&mut snapshots, at, |_, _| ProcessObservation::Alive);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Alive);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::LiveActive);

        monitor.apply(&mut snapshots, at + Duration::from_secs(1), |_, _| {
            ProcessObservation::CreationTimeMismatch {
                actual_started_at: at,
            }
        });

        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_eq!(snapshots[0].attention_state, AttentionState::Working);
        assert_ne!(snapshots[0].attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshots[0]
                .runtime_binding
                .as_ref()
                .map(|binding| binding.process_started_at),
            Some(expected_started_at)
        );
    }

    #[test]
    fn normal_exit_does_not_produce_lost_after_process_disappears() {
        let at = now();
        let mut snapshot = claude_snapshot("session-1", "D:\\ws", at);
        snapshot.set_attention(
            AttentionState::ResultReady,
            "hook: Claude Stop reported no background work",
            Some(at),
        );
        snapshot.set_session_liveness(
            SessionLiveness::Detached,
            "hook: Claude SessionEnd detached the current runtime",
            Some(at),
        );
        snapshot.active_runtime_id = None;
        let mut snapshots = vec![snapshot];
        let mut monitor = apply_with(
            launch_record(at),
            &mut snapshots,
            at,
            ProcessObservation::Alive,
        );
        monitor.apply(&mut snapshots, at + Duration::from_secs(1), |_, _| {
            ProcessObservation::Missing
        });

        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Detached);
        assert_eq!(snapshots[0].attention_state, AttentionState::ResultReady);
    }

    #[test]
    fn explicit_failed_turn_is_terminal_and_does_not_produce_lost() {
        let at = now();
        let mut snapshot = claude_snapshot("session-1", "D:\\ws", at);
        snapshot.set_attention(
            AttentionState::Interrupted,
            "codex exec --json: turn.failed or error",
            Some(at),
        );
        snapshot.set_session_liveness(
            SessionLiveness::LiveIdle,
            "codex exec --json: turn failed",
            Some(at),
        );
        snapshot.active_runtime_id = None;
        let mut snapshots = vec![snapshot];
        let mut monitor = apply_with(
            launch_record(at),
            &mut snapshots,
            at,
            ProcessObservation::Alive,
        );
        monitor.apply(&mut snapshots, at + Duration::from_secs(1), |_, _| {
            ProcessObservation::Missing
        });

        assert_eq!(snapshots[0].attention_state, AttentionState::Interrupted);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::LiveIdle);
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn exact_active_runtime_abnormal_exit_produces_lost_without_result_ready() {
        let at = now();
        let mut snapshots = vec![claude_snapshot("session-1", "D:\\ws", at)];
        let mut monitor = apply_with(
            launch_record(at),
            &mut snapshots,
            at,
            ProcessObservation::Alive,
        );
        monitor.apply(&mut snapshots, at + Duration::from_secs(1), |_, _| {
            ProcessObservation::Missing
        });

        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_ne!(snapshots[0].attention_state, AttentionState::ResultReady);
        assert_eq!(snapshots[0].attention_state, AttentionState::Working);
    }

    #[test]
    fn no_active_prompt_does_not_produce_lost() {
        let at = now();
        let mut record = launch_record(at);
        record.active_runtime_id = None;
        let mut snapshot = claude_snapshot("session-1", "D:\\ws", at);
        snapshot.active_runtime_id = None;
        snapshot.set_session_liveness(
            SessionLiveness::LiveIdle,
            "hook: Claude session lifecycle started",
            Some(at),
        );
        let mut snapshots = vec![snapshot];
        let mut monitor = apply_with(record, &mut snapshots, at, ProcessObservation::Alive);
        monitor.apply(&mut snapshots, at + Duration::from_secs(1), |_, _| {
            ProcessObservation::Missing
        });

        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn observer_offline_missed_exit_stays_unknown_not_lost() {
        let at = now();
        let mut snapshots = vec![claude_snapshot("session-1", "D:\\ws", at)];
        apply_with(
            launch_record(at),
            &mut snapshots,
            at,
            ProcessObservation::Missing,
        );

        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Unknown);
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].attention_state, AttentionState::Working);
        assert!(
            snapshots[0]
                .session_liveness_evidence
                .as_deref()
                .unwrap()
                .contains("did not observe")
                || snapshots[0]
                    .session_liveness_evidence
                    .as_deref()
                    .unwrap()
                    .contains("was not watching")
        );
    }

    #[test]
    fn crash_does_not_synthesize_result_ready() {
        let at = now();
        let mut snapshots = vec![claude_snapshot("session-1", "D:\\ws", at)];
        let mut monitor = apply_with(
            launch_record(at),
            &mut snapshots,
            at,
            ProcessObservation::Alive,
        );
        monitor.apply(&mut snapshots, at + Duration::from_secs(1), |_, _| {
            ProcessObservation::Missing
        });

        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_ne!(snapshots[0].attention_state, AttentionState::ResultReady);
        assert_eq!(snapshots[0].evidence_freshness, EvidenceFreshness::None);
    }

    #[test]
    fn same_cwd_old_and_new_sessions_stay_separate() {
        let at = now();
        let cwd = "D:\\agent-observer-runtime-binding-v1";
        let mut old = claude_snapshot("session-old", cwd, at);
        old.runtime_binding_id = Some("binding-old".to_string());
        let mut new = claude_snapshot("session-new", cwd, at);
        new.runtime_binding_id = Some("binding-new".to_string());
        let mut old_record = launch_record(at);
        old_record.runtime_binding_id = "binding-old".to_string();
        old_record.native_session_id = Some("session-old".to_string());
        let mut new_record = launch_record(at);
        new_record.runtime_binding_id = "binding-new".to_string();
        new_record.native_session_id = Some("session-new".to_string());
        new_record.process_id = 11;

        let mut snapshots = vec![old, new];
        let mut monitor = RuntimeMonitor::from_records("observer-1", vec![old_record, new_record]);
        monitor.apply(&mut snapshots, at, |pid, _| {
            if pid == 10 {
                ProcessObservation::Missing
            } else {
                ProcessObservation::Alive
            }
        });
        monitor.apply(&mut snapshots, at + Duration::from_secs(1), |pid, _| {
            if pid == 10 {
                ProcessObservation::Missing
            } else {
                ProcessObservation::Alive
            }
        });

        assert_eq!(snapshots[0].native_session_id, "session-old");
        assert_eq!(snapshots[1].native_session_id, "session-new");
        assert_eq!(snapshots[0].cwd, snapshots[1].cwd);
        assert_ne!(
            snapshots[0].runtime_binding_id.as_deref(),
            snapshots[1].runtime_binding_id.as_deref()
        );
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Unknown);
        assert_eq!(snapshots[1].session_liveness, SessionLiveness::LiveActive);
        assert_eq!(snapshots[1].host_liveness, HostLiveness::Alive);
    }

    #[test]
    fn cwd_alone_does_not_bind_a_new_session_to_an_old_launch() {
        let at = now();
        let mut snapshot = claude_snapshot("session-new", "D:\\ws", at);
        snapshot.runtime_binding_id = None;
        snapshot.native_session_id = "session-new".to_string();
        let mut snapshots = vec![snapshot];
        apply_with(
            launch_record(at),
            &mut snapshots,
            at,
            ProcessObservation::Missing,
        );

        assert!(snapshots[0].runtime_binding.is_none());
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn persisted_abnormal_exit_survives_a_new_observer_instance() {
        let at = now();
        let mut record = launch_record(at);
        record.abnormal_exit_observed_at = Some(at);
        let mut snapshots = vec![claude_snapshot("session-1", "D:\\ws", at)];
        apply_with(record, &mut snapshots, at, ProcessObservation::Missing);

        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
    }

    fn pi_launch_record(at: SystemTime) -> LaunchRecord {
        LaunchRecord {
            path: PathBuf::new(),
            runtime_binding_id: "pi-binding-1".to_string(),
            family: AgentFamily::Pi,
            native_session_id: Some("pi-session-1".to_string()),
            active_runtime_id: Some("prompt-1".to_string()),
            host_instance_id: "host:pid:20:started:1".to_string(),
            process_id: 20,
            process_started_at: at - Duration::from_secs(5),
            cwd: Some("D:\\pi-workspace".to_string()),
            launched_at: at - Duration::from_secs(5),
            binding_source: "pi-rpc-owned-stdio".to_string(),
            abnormal_exit_observed_at: None,
        }
    }

    #[test]
    fn parse_launch_record_accepts_pi_family() {
        let at = now();
        let dir = std::env::temp_dir().join(format!(
            "agent-observer-pi-parse-{}",
            unix_millis(SystemTime::now())
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("pi-binding.json");
        let started_ms = unix_millis(at - Duration::from_secs(5));
        fs::write(
            &path,
            format!(
                r#"{{"observer_schema":2,"record_type":"cli_runtime_launch","runtime_binding_id":"pi-binding-1","family":"Pi","surface":"CLI","cwd":"D:\\pi-workspace","process_id":20,"process_started_at_unix_ms":{started_ms},"host_instance_id":"host:pid:20:started:{started_ms}","launched_at_unix_ms":{started_ms},"native_session_id":"pi-session-1","active_runtime_id":"prompt-1","binding_source":"pi-rpc-owned-stdio","abnormal_exit_observed_at_unix_ms":null}}"#
            ),
        )
        .unwrap();

        let monitor = RuntimeMonitor::load(&dir, "observer-test");
        assert_eq!(monitor.records.len(), 1);
        assert_eq!(monitor.records[0].family, AgentFamily::Pi);
        assert_eq!(
            monitor.records[0].native_session_id.as_deref(),
            Some("pi-session-1")
        );
        assert_eq!(monitor.records[0].process_id, 20);
        assert_eq!(
            monitor.records[0].process_started_at,
            at - Duration::from_secs(5)
        );
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn pi_launch_record_json_round_trip_preserves_family_and_identity() {
        let at = now();
        let record = pi_launch_record(at);
        let value = serde_json::json!({
            "observer_schema": 2,
            "record_type": "cli_runtime_launch",
            "runtime_binding_id": record.runtime_binding_id,
            "family": record.family.to_string(),
            "surface": Surface::Cli.to_string(),
            "cwd": record.cwd,
            "process_id": record.process_id,
            "process_started_at_unix_ms": unix_millis(record.process_started_at),
            "host_instance_id": record.host_instance_id,
            "launched_at_unix_ms": unix_millis(record.launched_at),
            "native_session_id": record.native_session_id,
            "active_runtime_id": record.active_runtime_id,
            "binding_source": record.binding_source,
            "abnormal_exit_observed_at_unix_ms": record.abnormal_exit_observed_at.map(unix_millis),
        });
        let text = format!("{value}\n");

        // Parse through the same JSON representation persist_launch_record writes.
        let dir = std::env::temp_dir().join(format!(
            "agent-observer-pi-roundtrip-{}",
            unix_millis(SystemTime::now())
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("round-trip-pi.json");
        fs::write(&path, text).unwrap();
        let monitor = RuntimeMonitor::load(&dir, "observer-test");

        assert_eq!(monitor.records.len(), 1);
        let parsed = &monitor.records[0];
        assert_eq!(parsed.family, AgentFamily::Pi);
        assert_eq!(parsed.runtime_binding_id, "pi-binding-1");
        assert_eq!(parsed.native_session_id.as_deref(), Some("pi-session-1"));
        assert_eq!(parsed.active_runtime_id.as_deref(), Some("prompt-1"));
        assert_eq!(parsed.process_id, 20);
        assert_eq!(parsed.process_started_at, record.process_started_at);
        assert_eq!(parsed.cwd.as_deref(), Some("D:\\pi-workspace"));
        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn persisted_pi_abnormal_exit_is_recovered_after_restart() {
        let at = now();
        let mut record = pi_launch_record(at);
        record.abnormal_exit_observed_at = Some(at);
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Pi,
            Surface::Cli,
            "pi-session-1".to_string(),
            Some("D:\\pi-workspace".to_string()),
            "Pi RPC (Observer-owned stdio)".to_string(),
            at,
        );
        snapshot.runtime_binding_id = Some("pi-binding-1".to_string());
        snapshot.active_runtime_id = Some("prompt-1".to_string());
        snapshot.set_attention(
            AttentionState::Working,
            "Pi RPC agent_start received by Observer",
            Some(at),
        );
        snapshot.set_session_liveness(
            SessionLiveness::LiveActive,
            "Pi RPC agent_start received by Observer",
            Some(at),
        );
        let mut snapshots = vec![snapshot];
        apply_with(record, &mut snapshots, at, ProcessObservation::Missing);

        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_eq!(snapshots[0].attention_state, AttentionState::Working);
    }

    #[test]
    fn same_native_id_string_across_families_stays_independent() {
        let at = now();
        let shared_id = "uuid-shared".to_string();
        let mut codex = claude_snapshot(&shared_id, "D:\\ws", at);
        codex.family = AgentFamily::Codex;
        codex.runtime_binding_id = Some("binding-codex".to_string());
        let mut claude = claude_snapshot(&shared_id, "D:\\ws", at);
        claude.runtime_binding_id = Some("binding-claude".to_string());
        let mut pi = claude_snapshot(&shared_id, "D:\\ws", at);
        pi.family = AgentFamily::Pi;
        pi.runtime_binding_id = Some("binding-pi".to_string());

        let mut codex_record = launch_record(at);
        codex_record.family = AgentFamily::Codex;
        codex_record.runtime_binding_id = "binding-codex".to_string();
        let mut claude_record = launch_record(at);
        claude_record.runtime_binding_id = "binding-claude".to_string();
        let mut pi_record = pi_launch_record(at);
        pi_record.runtime_binding_id = "binding-pi".to_string();

        let mut snapshots = vec![codex, claude, pi];
        let mut monitor = RuntimeMonitor::from_records(
            "observer-1",
            vec![codex_record, claude_record, pi_record],
        );
        monitor.apply(&mut snapshots, at, |_, _| ProcessObservation::Missing);

        assert_eq!(
            snapshots[0].runtime_binding_id.as_deref(),
            Some("binding-codex")
        );
        assert_eq!(
            snapshots[1].runtime_binding_id.as_deref(),
            Some("binding-claude")
        );
        assert_eq!(
            snapshots[2].runtime_binding_id.as_deref(),
            Some("binding-pi")
        );
        assert_eq!(snapshots[0].family, AgentFamily::Codex);
        assert_eq!(snapshots[1].family, AgentFamily::Claude);
        assert_eq!(snapshots[2].family, AgentFamily::Pi);
        assert_eq!(
            snapshots[0].native_session_id,
            snapshots[2].native_session_id
        );
    }

    #[test]
    fn mismatched_abnormal_exit_fields_do_not_mark_lost() {
        let at = now();
        let mut snapshot = claude_snapshot("session-1", "D:\\ws", at);
        let binding = launch_record(at).exact_binding(at).unwrap();
        assert!(snapshot.bind_runtime(binding.clone()));
        let exit = AbnormalRuntimeExit {
            runtime_binding_id: binding.runtime_binding_id,
            native_session_id: binding.native_session_id,
            active_runtime_id: "prompt-other".to_string(),
            host_instance_id: binding.host_instance_id,
            process_id: binding.process_id,
            process_started_at: binding.process_started_at,
            observed_at: at,
        };
        assert!(!snapshot.mark_lost_from_abnormal_bound_exit(&exit));
    }
}
