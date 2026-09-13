use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, SystemTime};

use serde_json::{Value, json};

use crate::model::{
    AgentFamily, AttentionState, HostLiveness, SessionLiveness, SessionSnapshot, Surface,
    system_time_from_unix_millis, unix_millis,
};

/// Canonical source label for every Pi RPC evidence record and snapshot.
pub const SOURCE: &str = "Pi RPC (Observer-owned stdio)";
pub const RECORD_SOURCE: &str = "pi-rpc";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssistantOutcome {
    Normal,
    Failed,
    Unknown,
}

/// Single state machine for Pi RPC lifecycle. Both the owned runner and the
/// watch-time replay of persisted evidence use this one implementation so the
/// two views cannot drift apart.
#[derive(Debug, Clone)]
pub struct PiRpcState {
    pub runtime_binding_id: String,
    pub native_session_id: Option<String>,
    pub session_file: Option<String>,
    pub session_name: Option<String>,
    pub active_runtime_id: Option<String>,
    pub attention_state: AttentionState,
    pub attention_evidence: String,
    pub session_liveness: SessionLiveness,
    pub session_liveness_evidence: String,
    pub host_liveness: HostLiveness,
    pub host_liveness_evidence: Option<String>,
    pub last_attention_evidence_at: Option<SystemTime>,
    pub last_session_liveness_evidence_at: Option<SystemTime>,
    pub last_host_liveness_observed_at: Option<SystemTime>,
    pub last_source_activity_at: Option<SystemTime>,
    pub last_assistant_outcome: AssistantOutcome,
    pub is_streaming: Option<bool>,
    pub is_compacting: Option<bool>,
    pub pending_message_count: Option<u64>,
    pub saw_agent_start: bool,
    pub saw_agent_end: bool,
    pub saw_agent_settled: bool,
    pub saw_process_alive: bool,
    pub false_green: bool,
}

impl PiRpcState {
    pub fn new(runtime_binding_id: String) -> Self {
        Self {
            runtime_binding_id,
            native_session_id: None,
            session_file: None,
            session_name: None,
            active_runtime_id: None,
            attention_state: AttentionState::Unknown,
            attention_evidence: "no recognized Pi attention evidence".to_string(),
            session_liveness: SessionLiveness::Unknown,
            session_liveness_evidence: "no Pi session liveness evidence".to_string(),
            host_liveness: HostLiveness::Unknown,
            host_liveness_evidence: None,
            last_attention_evidence_at: None,
            last_session_liveness_evidence_at: None,
            last_host_liveness_observed_at: None,
            last_source_activity_at: None,
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

    fn note_source_activity(&mut self, observed_at: SystemTime) {
        self.last_source_activity_at = Some(
            self.last_source_activity_at
                .map(|current| current.max(observed_at))
                .unwrap_or(observed_at),
        );
    }

    fn note_attention(&mut self, state: AttentionState, evidence: &str, observed_at: SystemTime) {
        self.attention_state = state;
        self.attention_evidence = evidence.to_string();
        self.last_attention_evidence_at = Some(observed_at);
        self.note_source_activity(observed_at);
    }

    fn note_session_liveness(
        &mut self,
        liveness: SessionLiveness,
        evidence: &str,
        observed_at: SystemTime,
    ) {
        self.session_liveness = liveness;
        self.session_liveness_evidence = evidence.to_string();
        self.last_session_liveness_evidence_at = Some(observed_at);
        self.note_source_activity(observed_at);
    }

    /// Absorb one RPC frame. `prompt_id` is the Observer-owned request ID used
    /// as the active runtime ID under the single-outstanding-prompt rule.
    ///
    /// Semantics are the ones validated by the feasibility probe:
    /// - get_state updates metadata and (only if liveness was UNKNOWN) the
    ///   first session-liveness signal. It never refreshes attention evidence.
    /// - agent_start establishes WORKING + LIVE_ACTIVE and the active prompt.
    /// - agent_end records the assistant outcome but is explicitly
    ///   non-terminal; the active runtime stays until agent_settled.
    /// - agent_settled maps to RESULT_READY only after a recognized normal
    ///   assistant termination; error/abort/length maps to INTERRUPTED;
    ///   an unrecognized outcome maps to UNKNOWN.
    /// - auto_retry/compaction/summarization retry events keep WORKING.
    /// - only blocking extension_ui_request methods map to NEEDS_ME.
    pub fn absorb_frame(&mut self, frame: &Value, prompt_id: &str, observed_at: SystemTime) {
        if is_get_state_response(frame) {
            let data = &frame["data"];
            self.native_session_id =
                nonempty(data, "sessionId").or_else(|| self.native_session_id.take());
            self.session_file = nonempty(data, "sessionFile").or_else(|| self.session_file.take());
            self.session_name = nonempty(data, "sessionName").or_else(|| self.session_name.take());
            self.is_streaming = data.get("isStreaming").and_then(Value::as_bool);
            self.is_compacting = data.get("isCompacting").and_then(Value::as_bool);
            self.pending_message_count = data.get("pendingMessageCount").and_then(Value::as_u64);
            if self.session_liveness == SessionLiveness::Unknown {
                self.note_session_liveness(
                    if self.is_streaming == Some(true) {
                        SessionLiveness::LiveActive
                    } else {
                        SessionLiveness::LiveIdle
                    },
                    "Pi RPC get_state: session state observed; not a terminal event",
                    observed_at,
                );
            }
            self.note_source_activity(observed_at);
            return;
        }

        match frame.get("type").and_then(Value::as_str) {
            Some("agent_start") => {
                self.saw_agent_start = true;
                self.active_runtime_id = Some(prompt_id.to_string());
                self.note_attention(
                    AttentionState::Working,
                    "Pi RPC agent_start received by Observer",
                    observed_at,
                );
                self.note_session_liveness(
                    SessionLiveness::LiveActive,
                    "Pi RPC agent_start established an active prompt",
                    observed_at,
                );
            }
            Some("agent_end") => {
                self.saw_agent_end = true;
                // Live frames carry the full assistant message; persisted
                // evidence carries only the redacted assistantOutcome field.
                self.last_assistant_outcome = nonempty(frame, "assistantOutcome")
                    .map(|outcome| match outcome.as_str() {
                        "normal" => AssistantOutcome::Normal,
                        "failed" => AssistantOutcome::Failed,
                        _ => AssistantOutcome::Unknown,
                    })
                    .unwrap_or_else(|| assistant_outcome(frame));
                // Explicitly non-terminal: retry, compaction, or a queued
                // continuation may still arrive after agent_end.
                self.note_source_activity(observed_at);
            }
            Some("agent_settled") => {
                self.saw_agent_settled = true;
                self.active_runtime_id = None;
                self.note_session_liveness(
                    SessionLiveness::LiveIdle,
                    "Pi RPC agent_settled: no automatic continuation",
                    observed_at,
                );
                match self.last_assistant_outcome {
                    AssistantOutcome::Normal => self.note_attention(
                        AttentionState::ResultReady,
                        "Pi RPC agent_settled after normal assistant termination",
                        observed_at,
                    ),
                    AssistantOutcome::Failed => self.note_attention(
                        AttentionState::Interrupted,
                        "Pi RPC agent_settled after failed or aborted assistant termination",
                        observed_at,
                    ),
                    AssistantOutcome::Unknown => self.note_attention(
                        AttentionState::Unknown,
                        "Pi RPC agent_settled without a recognized assistant outcome",
                        observed_at,
                    ),
                }
            }
            Some("auto_retry_start")
            | Some("compaction_start")
            | Some("summarization_retry_scheduled")
            | Some("summarization_retry_attempt_start") => {
                self.note_attention(
                    AttentionState::Working,
                    "Pi RPC retry or compaction activity",
                    observed_at,
                );
            }
            Some("auto_retry_end")
            | Some("compaction_end")
            | Some("summarization_retry_completed") => {
                // The agent loop resumes; these are source activity only and
                // must not turn green before the next agent_start or settled.
                self.note_source_activity(observed_at);
            }
            Some("extension_ui_request") if is_blocking_ui_request(frame) => {
                self.note_attention(
                    AttentionState::NeedsMe,
                    "Pi RPC blocking extension UI request",
                    observed_at,
                );
            }
            _ => {
                // Any other valid RPC metadata frame is source activity only.
                self.note_source_activity(observed_at);
            }
        }
    }

    pub fn mark_process_alive(&mut self, observed_at: SystemTime) {
        self.saw_process_alive = true;
        self.host_liveness = HostLiveness::Alive;
        self.host_liveness_evidence =
            Some("Pi RPC owned child PID + creation time observed alive".to_string());
        self.last_host_liveness_observed_at = Some(observed_at);
        self.note_source_activity(observed_at);
    }

    pub fn mark_normal_process_exit(&mut self, observed_at: SystemTime) {
        self.host_liveness = HostLiveness::Dead;
        self.host_liveness_evidence =
            Some("Pi RPC owned child exited normally after stdin close".to_string());
        self.last_host_liveness_observed_at = Some(observed_at);
        if self.session_liveness != SessionLiveness::Lost {
            self.note_session_liveness(
                SessionLiveness::Detached,
                "Pi RPC stdin closed normally; owned process exited",
                observed_at,
            );
        }
        self.note_source_activity(observed_at);
    }

    /// Abnormal exit. `exact_binding` requires this Observer witnessed the
    /// exact child alive, has a native session id, an active prompt, and no
    /// agent_settled. Otherwise the exit cause is unknown.
    pub fn mark_abnormal_process_exit(&mut self, observed_at: SystemTime, exact_binding: bool) {
        self.host_liveness = HostLiveness::Dead;
        self.host_liveness_evidence =
            Some("Pi RPC owned child exited without a terminal lifecycle event".to_string());
        self.last_host_liveness_observed_at = Some(observed_at);
        if exact_binding
            && self.saw_process_alive
            && self.native_session_id.is_some()
            && self.active_runtime_id.is_some()
            && !self.saw_agent_settled
        {
            self.note_session_liveness(
                SessionLiveness::Lost,
                "exact active Pi RPC child exited without a terminal event",
                observed_at,
            );
        } else {
            self.note_session_liveness(
                SessionLiveness::Unknown,
                "Pi RPC child exited; exact alive observation or terminal evidence is missing",
                observed_at,
            );
        }
        self.false_green = self.attention_state == AttentionState::ResultReady;
    }

    pub fn to_snapshot(&self, cwd: Option<String>) -> Option<SessionSnapshot> {
        let native_session_id = self.native_session_id.clone()?;
        let source_activity_at = self.last_source_activity_at.unwrap_or_else(SystemTime::now);
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Pi,
            Surface::Cli,
            native_session_id,
            cwd,
            SOURCE.to_string(),
            source_activity_at,
        );
        snapshot.session_display_name = self.session_name.clone();
        snapshot.attention_state = self.attention_state;
        snapshot.attention_evidence = self.attention_evidence.clone();
        snapshot.host_liveness = self.host_liveness;
        snapshot.host_liveness_evidence = self.host_liveness_evidence.clone();
        snapshot.session_liveness = self.session_liveness;
        snapshot.session_liveness_evidence = Some(self.session_liveness_evidence.clone());
        snapshot.runtime_binding_id = Some(self.runtime_binding_id.clone());
        snapshot.active_runtime_id = self.active_runtime_id.clone();
        snapshot.last_attention_evidence_at = self.last_attention_evidence_at;
        snapshot.last_session_liveness_evidence_at = self.last_session_liveness_evidence_at;
        snapshot.last_host_liveness_observed_at = self.last_host_liveness_observed_at;
        snapshot.last_source_activity_at = source_activity_at;
        snapshot.last_observed_at = source_activity_at;
        Some(snapshot)
    }
}

/// Strict LF framing: split frames on the 0x0A byte only, accept one optional
/// trailing CR, and never treat U+2028/U+2029 (multi-byte UTF-8 inside JSON
/// strings) as separators.
pub fn read_lf_frames(stdout: impl Read, tx: Sender<Result<Vec<u8>, String>>) {
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

pub fn spawn_frame_reader(stdout: impl Read + Send + 'static) -> Receiver<Result<Vec<u8>, String>> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || read_lf_frames(stdout, tx));
    rx
}

pub fn parse_line(bytes: &[u8]) -> Option<Value> {
    serde_json::from_slice(bytes).ok()
}

pub fn is_get_state_response(frame: &Value) -> bool {
    frame.get("type").and_then(Value::as_str) == Some("response")
        && frame.get("command").and_then(Value::as_str) == Some("get_state")
        && frame.get("success").and_then(Value::as_bool) == Some(true)
}

pub fn is_blocking_ui_request(frame: &Value) -> bool {
    matches!(
        frame.get("method").and_then(Value::as_str),
        Some("select" | "confirm" | "input" | "editor")
    )
}

pub fn assistant_outcome(frame: &Value) -> AssistantOutcome {
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

pub fn assistant_message_outcome(message: &Value) -> AssistantOutcome {
    match message.get("stopReason").and_then(Value::as_str) {
        Some("stop") => AssistantOutcome::Normal,
        Some("error" | "aborted" | "length") => AssistantOutcome::Failed,
        _ => AssistantOutcome::Unknown,
    }
}

/// Metadata-only redaction. Drops prompt text, assistant output, thinking,
/// tool input/output, and every other content body. Keeps only IDs, event
/// types, lifecycle flags, and Observer receive time.
pub fn redact_frame(
    frame: &Value,
    runtime_binding_id: &str,
    cwd: &Path,
    active_runtime_id: Option<&str>,
    observed_at: SystemTime,
) -> Value {
    let frame_type = frame
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let mut value = json!({
        "observer_schema": 2,
        "source": RECORD_SOURCE,
        "runtime_binding_id": runtime_binding_id,
        "cwd": cwd.to_string_lossy(),
        "type": frame_type,
        "observed_at_unix_ms": unix_millis(observed_at),
        "provenance": "observer_received_at",
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
    let records_active_runtime = frame_type == "agent_start"
        || (frame_type == "response"
            && value.get("command").and_then(Value::as_str) == Some("prompt"));
    if records_active_runtime && let Some(active_runtime_id) = active_runtime_id {
        value["active_runtime_id"] = Value::String(active_runtime_id.to_string());
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

pub fn redact_process_alive(
    runtime_binding_id: &str,
    cwd: &Path,
    observed_at: SystemTime,
) -> Value {
    json!({
        "observer_schema": 2,
        "source": RECORD_SOURCE,
        "runtime_binding_id": runtime_binding_id,
        "cwd": cwd.to_string_lossy(),
        "type": "observer_process_alive",
        "observed_at_unix_ms": unix_millis(observed_at),
        "provenance": "observer_owned_child_poll",
    })
}

pub fn redact_process_exit(
    runtime_binding_id: &str,
    cwd: &Path,
    mode: &str,
    exact_binding: bool,
    observed_at: SystemTime,
) -> Value {
    json!({
        "observer_schema": 2,
        "source": RECORD_SOURCE,
        "runtime_binding_id": runtime_binding_id,
        "cwd": cwd.to_string_lossy(),
        "type": "observer_process_exit",
        "mode": mode,
        "exact_binding": exact_binding,
        "observed_at_unix_ms": unix_millis(observed_at),
        "provenance": "observer_owned_child_poll",
    })
}

/// Discover persisted Pi RPC evidence under `root` (the `pi-rpc` directory of
/// the runtime binding root) and replay it into one SessionSnapshot per
/// runtime binding.
pub fn discover(
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let mut paths = Vec::new();
    collect_event_logs(root, &mut paths);

    let mut by_binding: BTreeMap<String, SessionSnapshot> = BTreeMap::new();
    for snapshot in paths
        .into_iter()
        .filter_map(|path| replay_file(&path, now, stale_after, include_stale))
    {
        let key = snapshot
            .runtime_binding_id
            .clone()
            .unwrap_or_else(|| snapshot.native_session_id.clone());
        match by_binding.get_mut(&key) {
            Some(existing)
                if existing.last_source_activity_at >= snapshot.last_source_activity_at => {}
            _ => {
                by_binding.insert(key, snapshot);
            }
        }
    }
    let mut snapshots = by_binding.into_values().collect::<Vec<_>>();
    snapshots.sort_by_key(|snapshot| std::cmp::Reverse(snapshot.last_source_activity_at));
    snapshots
}

fn collect_event_logs(root: &Path, paths: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_event_logs(&path, paths);
        } else if path.extension().and_then(|extension| extension.to_str()) == Some("jsonl") {
            paths.push(path);
        }
    }
}

fn replay_file(
    path: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Option<SessionSnapshot> {
    let metadata = fs::metadata(path).ok()?;
    let modified = metadata.modified().ok()?;
    let source_age = now.duration_since(modified).unwrap_or(Duration::ZERO);
    if !include_stale && source_age > stale_after {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    replay_records(&text)
}

fn replay_records(text: &str) -> Option<SessionSnapshot> {
    let mut runtime_binding_id = None;
    let mut cwd = None;
    let mut state: Option<PiRpcState> = None;

    for line in text.lines() {
        let line = line.trim().trim_start_matches('\u{feff}');
        if line.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if value.get("observer_schema").and_then(Value::as_u64) != Some(2) {
            continue;
        }
        if value.get("source").and_then(Value::as_str) != Some(RECORD_SOURCE) {
            continue;
        }
        let observed_at = value
            .get("observed_at_unix_ms")
            .and_then(json_u128)
            .and_then(system_time_from_unix_millis)?;
        let record_binding_id = nonempty(&value, "runtime_binding_id")?;
        runtime_binding_id = Some(record_binding_id.clone());
        cwd = nonempty(&value, "cwd").or(cwd);
        let state_ref = state.get_or_insert_with(|| PiRpcState::new(record_binding_id.clone()));

        let frame_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        match frame_type {
            "observer_process_alive" => state_ref.mark_process_alive(observed_at),
            "observer_process_exit" => {
                let mode = nonempty(&value, "mode").unwrap_or_else(|| "abnormal".to_string());
                let exact_binding = value
                    .get("exact_binding")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if mode == "normal" {
                    state_ref.mark_normal_process_exit(observed_at);
                } else {
                    state_ref.mark_abnormal_process_exit(observed_at, exact_binding);
                }
            }
            _ => {
                let active_runtime_id = nonempty(&value, "active_runtime_id");
                // Replay needs the same prompt id the live runner used for the
                // active runtime. The single-outstanding-prompt rule makes the
                // recorded request ID authoritative; without one, agent_start
                // falls back to a stable per-binding token so the binding
                // remains exact even after restart.
                let prompt_id = active_runtime_id.as_deref().unwrap_or("replayed-prompt");
                state_ref.absorb_frame(&value, prompt_id, observed_at);
            }
        }
    }

    let mut state = state?;
    let binding_id = runtime_binding_id?;
    state.runtime_binding_id = binding_id;
    state.to_snapshot(cwd)
}

fn nonempty(value: &Value, field: &str) -> Option<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn json_u128(value: &Value) -> Option<u128> {
    value
        .as_u64()
        .map(u128::from)
        .or_else(|| value.as_str()?.parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> PiRpcState {
        let mut state = PiRpcState::new("pi-binding-1".to_string());
        state.native_session_id = Some("pi-session-1".to_string());
        state.mark_process_alive(SystemTime::UNIX_EPOCH + Duration::from_millis(1_000));
        state
    }

    fn at(millis: u128) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_millis(u64::try_from(millis).unwrap_or(u64::MAX))
    }

    #[test]
    fn agent_start_is_working_and_binds_active_runtime() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));

        assert_eq!(state.attention_state, AttentionState::Working);
        assert_eq!(state.session_liveness, SessionLiveness::LiveActive);
        assert_eq!(state.active_runtime_id.as_deref(), Some("prompt-1"));
    }

    #[test]
    fn agent_end_alone_never_turns_green() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));
        state.absorb_frame(
            &json!({"type":"agent_end","willRetry":false,"messages":[{"role":"assistant","stopReason":"stop","content":"private"}]}),
            "prompt-1",
            at(1_200),
        );

        assert_eq!(state.attention_state, AttentionState::Working);
        assert_eq!(state.active_runtime_id.as_deref(), Some("prompt-1"));
        assert!(!state.saw_agent_settled);
    }

    #[test]
    fn settled_after_normal_assistant_is_result_ready() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));
        state.absorb_frame(
            &json!({"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop"}]}),
            "prompt-1",
            at(1_200),
        );
        state.absorb_frame(&json!({"type":"agent_settled"}), "prompt-1", at(1_300));

        assert_eq!(state.attention_state, AttentionState::ResultReady);
        assert_eq!(state.session_liveness, SessionLiveness::LiveIdle);
        assert_eq!(state.active_runtime_id, None);
    }

    #[test]
    fn settled_after_error_is_interrupted_not_green() {
        for stop_reason in ["error", "aborted", "length"] {
            let mut state = state();
            state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));
            state.absorb_frame(
                &json!({"type":"agent_end","messages":[{"role":"assistant","stopReason":stop_reason}]}),
                "prompt-1",
                at(1_200),
            );
            state.absorb_frame(&json!({"type":"agent_settled"}), "prompt-1", at(1_300));

            assert_eq!(state.attention_state, AttentionState::Interrupted);
            assert_ne!(state.attention_state, AttentionState::ResultReady);
        }
    }

    #[test]
    fn settled_with_unknown_outcome_is_unknown_not_green() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));
        state.absorb_frame(
            &json!({"type":"agent_end","messages":[{"role":"assistant"}]}),
            "prompt-1",
            at(1_200),
        );
        state.absorb_frame(&json!({"type":"agent_settled"}), "prompt-1", at(1_300));

        assert_eq!(state.attention_state, AttentionState::Unknown);
    }

    #[test]
    fn retry_and_compaction_events_keep_working() {
        for event_type in [
            "auto_retry_start",
            "compaction_start",
            "summarization_retry_scheduled",
            "summarization_retry_attempt_start",
        ] {
            let mut state = state();
            state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));
            state.absorb_frame(
                &json!({"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop"}]}),
                "prompt-1",
                at(1_200),
            );
            state.absorb_frame(&json!({"type":event_type}), "prompt-1", at(1_300));

            assert_eq!(state.attention_state, AttentionState::Working);
            assert!(!state.saw_agent_settled);
            assert_eq!(state.active_runtime_id.as_deref(), Some("prompt-1"));
        }
    }

    #[test]
    fn only_blocking_extension_ui_requests_need_attention() {
        for method in ["select", "confirm", "input", "editor"] {
            let mut blocking = state();
            blocking.absorb_frame(
                &json!({"type":"extension_ui_request","id":"ui-1","method":method,"message":"private"}),
                "prompt-1",
                at(1_100),
            );
            assert_eq!(blocking.attention_state, AttentionState::NeedsMe);
        }

        for method in [
            "notify",
            "setStatus",
            "setWidget",
            "setTitle",
            "set_editor_text",
        ] {
            let mut notify = state();
            notify.absorb_frame(
                &json!({"type":"extension_ui_request","id":"ui-2","method":method,"message":"private"}),
                "prompt-1",
                at(1_100),
            );
            assert_eq!(notify.attention_state, AttentionState::Unknown);
        }
    }

    #[test]
    fn get_state_does_not_refresh_attention_evidence() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_000));
        let before = state.last_attention_evidence_at;

        state.absorb_frame(
            &json!({"type":"response","id":"state-2","command":"get_state","success":true,"data":{"sessionId":"pi-session-1","sessionFile":"f.jsonl","sessionName":"Pi并行会话A_日本語","isStreaming":false,"isCompacting":false,"pendingMessageCount":1}}),
            "prompt-1",
            at(2_000),
        );

        assert_eq!(state.last_attention_evidence_at, before);
        assert_eq!(state.attention_state, AttentionState::Working);
        assert_eq!(state.session_name.as_deref(), Some("Pi并行会话A_日本語"));
    }

    #[test]
    fn ordinary_frames_move_source_activity_but_not_attention() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_000));
        let before = state.last_attention_evidence_at;

        state.absorb_frame(&json!({"type":"auto_retry_end"}), "prompt-1", at(1_400));

        assert_eq!(state.last_attention_evidence_at, before);
        assert!(state.last_source_activity_at.unwrap() > at(1_000));
    }

    #[test]
    fn exact_active_kill_is_lost_without_false_green() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));
        state.mark_abnormal_process_exit(at(1_200), true);

        assert_eq!(state.attention_state, AttentionState::Working);
        assert_eq!(state.session_liveness, SessionLiveness::Lost);
        assert!(!state.false_green);
    }

    #[test]
    fn observer_never_saw_alive_stays_unknown() {
        let mut state = PiRpcState::new("pi-binding-1".to_string());
        state.native_session_id = Some("pi-session-1".to_string());
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));
        state.mark_abnormal_process_exit(at(1_200), true);

        assert_eq!(state.session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn normal_exit_is_detached_not_lost() {
        let mut state = state();
        state.absorb_frame(&json!({"type":"agent_start"}), "prompt-1", at(1_100));
        state.absorb_frame(
            &json!({"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop"}]}),
            "prompt-1",
            at(1_200),
        );
        state.absorb_frame(&json!({"type":"agent_settled"}), "prompt-1", at(1_300));
        state.mark_normal_process_exit(at(1_400));

        assert_eq!(state.session_liveness, SessionLiveness::Detached);
        assert_eq!(state.attention_state, AttentionState::ResultReady);
        assert_ne!(state.session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn redaction_drops_prompt_assistant_thinking_and_tool_bodies() {
        let raw = json!({
            "type":"agent_end",
            "willRetry":false,
            "messages":[{"role":"assistant","stopReason":"stop","content":"secret output","thinking":"secret reasoning"}],
            "prompt":"secret prompt",
            "toolName":"bash",
            "toolCallId":"call-1",
            "toolInput":{"command":"secret command"}
        });
        let redacted = redact_frame(
            &raw,
            "pi-binding-1",
            Path::new("D:\\ws"),
            Some("prompt-1"),
            SystemTime::UNIX_EPOCH,
        )
        .to_string();

        assert!(redacted.contains("normal"));
        assert!(redacted.contains("bash"));
        assert!(redacted.contains("call-1"));
        assert!(!redacted.contains("secret output"));
        assert!(!redacted.contains("secret reasoning"));
        assert!(!redacted.contains("secret prompt"));
        assert!(!redacted.contains("secret command"));
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

    #[test]
    fn strict_lf_framing_strips_optional_cr() {
        let (tx, rx) = mpsc::channel();
        let input = b"{\"a\":1}\r\n{\"a\":2}\n";
        read_lf_frames(&input[..], tx);
        let first = rx.recv().unwrap().unwrap();
        let second = rx.recv().unwrap().unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&first).unwrap()["a"], 1);
        assert_eq!(serde_json::from_slice::<Value>(&second).unwrap()["a"], 2);
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn replay_normal_lifecycle_builds_result_ready_snapshot() {
        let text = r#"{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"observer_process_alive","observed_at_unix_ms":1000}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"response","id":"state-1","command":"get_state","success":true,"data":{"sessionId":"pi-session-1","sessionFile":"f.jsonl","sessionName":"Pi并行会话A_日本語","isStreaming":false,"isCompacting":false,"pendingMessageCount":0},"observed_at_unix_ms":1100}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"agent_start","active_runtime_id":"prompt-1","observed_at_unix_ms":1200}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"agent_end","willRetry":false,"assistantOutcome":"normal","observed_at_unix_ms":1300}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"agent_settled","observed_at_unix_ms":1400}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"observer_process_exit","mode":"normal","exact_binding":false,"observed_at_unix_ms":1500}
"#;
        let snapshot = replay_records(text).unwrap();

        assert_eq!(snapshot.family, AgentFamily::Pi);
        assert_eq!(snapshot.surface, Surface::Cli);
        assert_eq!(snapshot.native_session_id, "pi-session-1");
        assert_eq!(
            snapshot.session_display_name.as_deref(),
            Some("Pi并行会话A_日本語")
        );
        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Detached);
        assert_eq!(snapshot.host_liveness, HostLiveness::Dead);
        assert_eq!(snapshot.active_runtime_id, None);
        assert_eq!(snapshot.runtime_binding_id.as_deref(), Some("pi-binding-1"));
    }

    #[test]
    fn replay_settled_without_exit_record_stays_alive_live_idle() {
        // The legal window after agent_settled and before the real process
        // exit is confirmed: RESULT_READY + ALIVE + LIVE_IDLE. DETACHED and
        // DEAD may only appear once the exit evidence exists.
        let text = r#"{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"observer_process_alive","observed_at_unix_ms":1000}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"response","id":"state-1","command":"get_state","success":true,"data":{"sessionId":"pi-session-1","sessionFile":"f.jsonl","sessionName":"Pi正常完成验证_日本語","isStreaming":false,"isCompacting":false,"pendingMessageCount":0},"observed_at_unix_ms":1100}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"agent_start","active_runtime_id":"prompt-1","observed_at_unix_ms":1200}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"agent_end","willRetry":false,"assistantOutcome":"normal","observed_at_unix_ms":1300}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"agent_settled","observed_at_unix_ms":1400}
"#;
        let snapshot = replay_records(text).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.host_liveness, HostLiveness::Alive);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveIdle);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Detached);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshot.host_liveness, HostLiveness::Alive);
    }

    #[test]
    fn replay_exact_abnormal_exit_is_lost_while_working() {
        let text = r#"{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"observer_process_alive","observed_at_unix_ms":1000}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"response","id":"state-1","command":"get_state","success":true,"data":{"sessionId":"pi-session-1","sessionFile":"f.jsonl","sessionName":"Pi精确强杀验证_日本語","isStreaming":false,"isCompacting":false,"pendingMessageCount":0},"observed_at_unix_ms":1100}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"agent_start","active_runtime_id":"prompt-1","observed_at_unix_ms":1200}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"observer_process_exit","mode":"abnormal","exact_binding":true,"observed_at_unix_ms":1300}
"#;
        let snapshot = replay_records(text).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshot.host_liveness, HostLiveness::Dead);
        assert_eq!(snapshot.active_runtime_id.as_deref(), Some("prompt-1"));
    }

    #[test]
    fn replay_without_exit_record_keeps_working_active() {
        let text = r#"{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"observer_process_alive","observed_at_unix_ms":1000}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"response","id":"state-1","command":"get_state","success":true,"data":{"sessionId":"pi-session-1","sessionFile":"f.jsonl","sessionName":"Pi重启错过退出验证_日本語","isStreaming":false,"isCompacting":false,"pendingMessageCount":0},"observed_at_unix_ms":1100}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"agent_start","active_runtime_id":"prompt-1","observed_at_unix_ms":1200}
"#;
        let snapshot = replay_records(text).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveActive);
        assert_eq!(snapshot.host_liveness, HostLiveness::Alive);
    }

    #[test]
    fn replay_get_state_only_identity_has_no_attention_evidence() {
        let text = r#"{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"observer_process_alive","observed_at_unix_ms":1000}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"response","id":"state-1","command":"get_state","success":true,"data":{"sessionId":"pi-session-1","sessionFile":"f.jsonl","sessionName":"Pi并行会话B_日本語","isStreaming":false,"isCompacting":false,"pendingMessageCount":0},"observed_at_unix_ms":1100}
{"observer_schema":2,"source":"pi-rpc","runtime_binding_id":"pi-binding-1","cwd":"D:\\ws","type":"observer_process_exit","mode":"normal","exact_binding":false,"observed_at_unix_ms":1200}
"#;
        let snapshot = replay_records(text).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Unknown);
        assert_eq!(
            snapshot.session_display_name.as_deref(),
            Some("Pi并行会话B_日本語")
        );
        assert_eq!(snapshot.session_liveness, SessionLiveness::Detached);
        assert_eq!(snapshot.last_attention_evidence_at, None);
    }
}
