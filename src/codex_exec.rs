use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::model::{
    AgentFamily, AttentionState, SessionLiveness, SessionSnapshot, Surface, parse_rfc3339_utc,
    system_time_from_unix_millis, unix_millis,
};

pub fn redact_raw_event(
    line: &str,
    runtime_binding_id: &str,
    cwd: &Path,
    observed_at: SystemTime,
) -> Option<Value> {
    let raw: Value = serde_json::from_str(line).ok()?;
    let event_type = raw.get("type").and_then(Value::as_str)?;
    let mut redacted = serde_json::json!({
        "observer_schema": 2,
        "source": "codex-exec-json",
        "runtime_binding_id": runtime_binding_id,
        "cwd": cwd.to_string_lossy(),
        "type": event_type,
        "observed_at_unix_ms": unix_millis(observed_at),
    });
    if let Some(thread_id) = raw.get("thread_id").and_then(Value::as_str) {
        redacted["thread_id"] = Value::String(thread_id.to_string());
    }
    if let Some(item) = raw.get("item").and_then(Value::as_object) {
        for (source, target) in [
            ("id", "item_id"),
            ("type", "item_type"),
            ("status", "item_status"),
        ] {
            if let Some(value) = item.get(source).and_then(Value::as_str) {
                redacted[target] = Value::String(value.to_string());
            }
        }
    }
    Some(redacted)
}

pub fn discover(
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let mut paths = Vec::new();
    collect_event_logs(root, &mut paths);

    let mut by_native_id: BTreeMap<String, SessionSnapshot> = BTreeMap::new();
    for snapshot in paths
        .into_iter()
        .filter_map(|path| parse_file(&path, now, stale_after, include_stale))
    {
        let key = snapshot.native_session_id.clone();
        match by_native_id.get(&key) {
            Some(existing)
                if existing.last_source_activity_at >= snapshot.last_source_activity_at => {}
            _ => {
                by_native_id.insert(key, snapshot);
            }
        }
    }
    let mut snapshots = by_native_id.into_values().collect::<Vec<_>>();
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

fn parse_file(
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
    let mut snapshot = parse_event_log(path, &text, modified)?;
    snapshot.apply_evidence_freshness(now, stale_after);
    Some(snapshot)
}

fn parse_event_log(
    path: &Path,
    text: &str,
    fallback_source_activity_at: SystemTime,
) -> Option<SessionSnapshot> {
    let mut native_id = None;
    let mut cwd = None;
    let mut runtime_binding_id = None;
    let mut active_runtime_id = None;
    let mut attention = None;
    let mut session_liveness = None;
    let mut last_source_activity_at = None;
    let mut saw_exact_thread = false;

    for line in text
        .lines()
        .map(|line| line.trim().trim_start_matches('\u{feff}'))
        .filter(|line| !line.is_empty())
    {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if value.get("observer_schema").and_then(Value::as_u64) != Some(2) {
            continue;
        }
        if value.get("source").and_then(Value::as_str) != Some("codex-exec-json") {
            continue;
        }

        let event_at = value
            .get("observed_at_unix_ms")
            .and_then(json_u128)
            .and_then(system_time_from_unix_millis)
            .or_else(|| {
                value
                    .get("observed_at_utc")
                    .and_then(Value::as_str)
                    .and_then(parse_rfc3339_utc)
            });
        if let Some(event_at) = event_at {
            last_source_activity_at = Some(
                last_source_activity_at
                    .map(|current: SystemTime| current.max(event_at))
                    .unwrap_or(event_at),
            );
        }
        if let Some(id) = nonempty(&value, "runtime_binding_id") {
            runtime_binding_id = Some(id);
        }
        if let Some(id) = nonempty(&value, "thread_id") {
            native_id = Some(id.clone());
            saw_exact_thread = true;
        }
        cwd = nonempty(&value, "cwd").or(cwd);

        let Some(event_type) = value.get("type").and_then(Value::as_str) else {
            continue;
        };
        match event_type {
            "thread.started" => {
                session_liveness = Some((
                    SessionLiveness::LiveIdle,
                    "codex exec --json: thread.started from the launched process stdout"
                        .to_string(),
                    event_at,
                ));
            }
            "turn.started" => {
                if let Some(thread_id) = native_id.as_deref() {
                    active_runtime_id = Some(format!("{thread_id}:turn"));
                }
                attention = Some((
                    AttentionState::Working,
                    "codex exec --json: turn.started".to_string(),
                    event_at,
                ));
                session_liveness = Some((
                    SessionLiveness::LiveActive,
                    "codex exec --json: active turn from the launched process stdout".to_string(),
                    event_at,
                ));
            }
            "turn.completed" => {
                active_runtime_id = None;
                attention = Some((
                    AttentionState::ResultReady,
                    "codex exec --json: turn.completed".to_string(),
                    event_at,
                ));
                session_liveness = Some((
                    SessionLiveness::LiveIdle,
                    "codex exec --json: turn completed".to_string(),
                    event_at,
                ));
            }
            "turn.failed" | "error" => {
                active_runtime_id = None;
                attention = Some((
                    AttentionState::Interrupted,
                    "codex exec --json: turn.failed or error".to_string(),
                    event_at,
                ));
                session_liveness = Some((
                    SessionLiveness::LiveIdle,
                    "codex exec --json: turn failed".to_string(),
                    event_at,
                ));
            }
            _ => {}
        }
    }

    if !saw_exact_thread {
        return None;
    }
    let native_session_id = native_id.or_else(|| {
        path.file_stem()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
    })?;
    let mut snapshot = SessionSnapshot::new(
        AgentFamily::Codex,
        Surface::Cli,
        native_session_id,
        cwd,
        "codex exec --json (launched-process stdout)".to_string(),
        last_source_activity_at.unwrap_or(fallback_source_activity_at),
    );
    snapshot.runtime_binding_id = runtime_binding_id;
    snapshot.active_runtime_id = active_runtime_id;
    if let Some((state, evidence, observed_at)) = attention {
        snapshot.set_attention(state, evidence, observed_at);
    }
    if let Some((liveness, evidence, observed_at)) = session_liveness {
        snapshot.set_session_liveness(liveness, evidence, observed_at);
    }
    Some(snapshot)
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

    #[test]
    fn exec_json_thread_and_turn_bind_without_using_cwd_heuristics() {
        let events = r#"
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","cwd":"D:\\ws","type":"thread.started","thread_id":"thread-1","observed_at_utc":"2026-08-26T10:00:00Z"}
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","cwd":"D:\\ws","type":"turn.started","thread_id":"thread-1","observed_at_utc":"2026-08-26T10:00:01Z"}
"#;
        let snapshot =
            parse_event_log(Path::new("bind-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.native_session_id, "thread-1");
        assert_eq!(snapshot.runtime_binding_id.as_deref(), Some("bind-1"));
        assert_eq!(snapshot.active_runtime_id.as_deref(), Some("thread-1:turn"));
        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveActive);
        assert_eq!(snapshot.surface, Surface::Cli);
    }

    #[test]
    fn exec_json_turn_completed_clears_active_runtime() {
        let events = r#"
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"thread.started","thread_id":"thread-1","observed_at_utc":"2026-08-26T10:00:00Z"}
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"turn.started","thread_id":"thread-1","observed_at_utc":"2026-08-26T10:00:01Z"}
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"turn.completed","thread_id":"thread-1","observed_at_utc":"2026-08-26T10:00:02Z"}
"#;
        let snapshot =
            parse_event_log(Path::new("bind-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveIdle);
        assert_eq!(snapshot.active_runtime_id, None);
    }

    #[test]
    fn exec_json_turn_failed_is_terminal_and_clears_active_runtime() {
        let events = r#"
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"thread.started","thread_id":"thread-1","observed_at_utc":"2026-08-26T10:00:00Z"}
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"turn.started","observed_at_utc":"2026-08-26T10:00:01Z"}
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"turn.failed","observed_at_utc":"2026-08-26T10:00:02Z"}
"#;
        let snapshot =
            parse_event_log(Path::new("bind-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Interrupted);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveIdle);
        assert_eq!(snapshot.active_runtime_id, None);
    }

    #[test]
    fn exec_json_without_thread_id_is_not_an_exact_session() {
        let events = r#"{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"turn.started","observed_at_utc":"2026-08-26T10:00:00Z"}"#;
        assert!(parse_event_log(Path::new("bind-1.jsonl"), events, SystemTime::now()).is_none());
    }

    #[test]
    fn exec_json_ignores_item_bodies_and_keeps_only_type_metadata() {
        let events = r#"
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"thread.started","thread_id":"thread-1","observed_at_utc":"2026-08-26T10:00:00Z"}
{"observer_schema":2,"source":"codex-exec-json","runtime_binding_id":"bind-1","type":"item.completed","item_id":"item_1","item_type":"agent_message","observed_at_utc":"2026-08-26T10:00:01Z"}
"#;
        let snapshot =
            parse_event_log(Path::new("bind-1.jsonl"), events, SystemTime::now()).unwrap();
        assert!(!format!("{snapshot:?}").contains("prompt"));
        assert_eq!(snapshot.native_session_id, "thread-1");
    }

    #[test]
    fn raw_exec_redaction_drops_agent_text_and_command_content() {
        let raw = r#"{"type":"item.completed","thread_id":"thread-1","item":{"id":"item-1","type":"agent_message","status":"completed","text":"private reply","command":"secret command"}}"#;
        let redacted = redact_raw_event(
            raw,
            "binding-1",
            Path::new("D:\\ws"),
            SystemTime::UNIX_EPOCH,
        )
        .unwrap();
        let text = redacted.to_string();

        assert!(text.contains("item-1"));
        assert!(text.contains("agent_message"));
        assert!(!text.contains("private reply"));
        assert!(!text.contains("secret command"));
    }
}
