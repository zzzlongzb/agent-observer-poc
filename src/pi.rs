use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::model::{
    AgentFamily, AttentionState, HostLiveness, SessionLiveness, SessionSnapshot, Surface,
    parse_rfc3339_utc, presentation_session_name, system_time_from_unix_millis,
};
use crate::process::{ProcessObservation, observe_expected};

pub fn discover(
    session_root: &Path,
    hook_root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let mut snapshots = discover_journals(session_root, now, stale_after, include_stale);
    snapshots.extend(discover_hooks(hook_root, now, stale_after, include_stale));
    snapshots
}

fn discover_journals(
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let mut paths = Vec::new();
    collect_files(root, "jsonl", &mut paths);
    let mut by_id: BTreeMap<String, SessionSnapshot> = BTreeMap::new();
    for path in paths {
        let Some(snapshot) = parse_journal_file(&path, now, stale_after, include_stale) else {
            continue;
        };
        let key = snapshot.native_session_id.clone();
        match by_id.get(&key) {
            Some(existing)
                if existing.last_source_activity_at >= snapshot.last_source_activity_at => {}
            _ => {
                by_id.insert(key, snapshot);
            }
        }
    }
    by_id.into_values().collect()
}

fn parse_journal_file(
    path: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Option<SessionSnapshot> {
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    if !include_stale && now.duration_since(modified).unwrap_or_default() > stale_after {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    let mut snapshot = parse_journal(&text, modified)?;
    snapshot.apply_evidence_freshness(now, stale_after);
    Some(snapshot)
}

fn parse_journal(text: &str, fallback_source_activity_at: SystemTime) -> Option<SessionSnapshot> {
    let mut native_id = None;
    let mut cwd = None;
    let mut display_name = None;
    let mut attention = None;
    let mut last_source_activity_at = None;

    for value in json_lines(text) {
        let entry_at = pi_entry_timestamp(&value);
        update_latest(&mut last_source_activity_at, entry_at);
        match value.get("type").and_then(Value::as_str) {
            Some("session") => {
                native_id = string_field(&value, "id").or(native_id);
                cwd = string_field(&value, "cwd").or(cwd);
            }
            Some("session_info") => {
                display_name = value
                    .get("name")
                    .and_then(Value::as_str)
                    .and_then(presentation_session_name)
                    .or(display_name);
            }
            Some("message") => {
                if let Some((state, evidence)) = pi_message_attention(&value) {
                    attention = Some((state, evidence, entry_at));
                }
            }
            _ => {}
        }
    }

    let mut snapshot = SessionSnapshot::new(
        AgentFamily::Pi,
        Surface::Cli,
        native_id?,
        cwd,
        "pi-journal (passive)".to_string(),
        last_source_activity_at.unwrap_or(fallback_source_activity_at),
    );
    snapshot.session_display_name = display_name;
    if let Some((state, evidence, at)) = attention {
        snapshot.set_attention(state, evidence, at);
    }
    // A journal identifies the session, not the process currently hosting it.
    snapshot.set_session_liveness(
        SessionLiveness::Unknown,
        "passive Pi journal has no exact live runtime binding",
        None,
    );
    Some(snapshot)
}

fn pi_message_attention(value: &Value) -> Option<(AttentionState, &'static str)> {
    let message = value.get("message")?;
    match message.get("role").and_then(Value::as_str)? {
        "user" => Some((AttentionState::Working, "Pi journal user message submitted")),
        "toolResult" => Some((AttentionState::Working, "Pi journal tool result recorded")),
        "assistant" => match message.get("stopReason").and_then(Value::as_str) {
            Some("stop" | "length") => Some((
                AttentionState::Working,
                "Pi journal assistant segment ended; agent_settled has not been observed",
            )),
            Some("error" | "aborted") => Some((
                AttentionState::Interrupted,
                "Pi journal assistant turn interrupted",
            )),
            Some("toolUse" | "pending") => {
                Some((AttentionState::Working, "Pi journal agent is using tools"))
            }
            _ => None,
        },
        _ => None,
    }
}

fn discover_hooks(
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let mut paths = Vec::new();
    collect_files(root, "jsonl", &mut paths);
    let mut by_id = BTreeMap::new();
    for path in paths {
        let Ok(metadata) = fs::metadata(&path) else {
            continue;
        };
        let Ok(modified) = metadata.modified() else {
            continue;
        };
        if !include_stale && now.duration_since(modified).unwrap_or_default() > stale_after {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let Some(mut snapshot) = parse_hook_log(&text, modified, now) else {
            continue;
        };
        snapshot.apply_evidence_freshness(now, stale_after);
        by_id.insert(snapshot.native_session_id.clone(), snapshot);
    }
    by_id.into_values().collect()
}

fn parse_hook_log(
    text: &str,
    fallback_source_activity_at: SystemTime,
    now: SystemTime,
) -> Option<SessionSnapshot> {
    let mut native_id = None;
    let mut cwd = None;
    let mut display_name = None;
    let mut attention = None;
    let mut detached_at = None;
    let mut last_source_activity_at = None;
    let mut process_identity = None;
    let mut saw_no_session_true = false;
    let mut saw_no_session_false = false;

    for value in json_lines(text).filter(|value| {
        value.get("observer_schema").and_then(Value::as_u64) == Some(1)
            && value.get("source").and_then(Value::as_str) == Some("pi-extension")
    }) {
        let event_at = value
            .get("observed_at_unix_ms")
            .and_then(Value::as_u64)
            .and_then(|value| system_time_from_unix_millis(u128::from(value)));
        match value.get("no_session") {
            Some(Value::Bool(true)) => saw_no_session_true = true,
            Some(Value::Bool(false)) => saw_no_session_false = true,
            _ => {}
        }
        update_latest(&mut last_source_activity_at, event_at);
        native_id = string_field(&value, "session_id").or(native_id);
        cwd = string_field(&value, "cwd").or(cwd);
        display_name = value
            .get("session_name")
            .and_then(Value::as_str)
            .and_then(presentation_session_name)
            .or(display_name);
        if let (Some(process_id), Some(started_at)) = (
            value
                .get("process_id")
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok()),
            value
                .get("process_started_at_unix_ms")
                .and_then(Value::as_u64)
                .and_then(|value| system_time_from_unix_millis(u128::from(value))),
        ) {
            process_identity = Some((process_id, started_at));
        }
        match value.get("event").and_then(Value::as_str) {
            Some("agent_start" | "turn_start") => {
                attention = Some((
                    AttentionState::Working,
                    "Pi extension observed an active agent turn",
                    event_at,
                ));
            }
            Some("agent_settled") => {
                attention = Some((
                    AttentionState::ResultReady,
                    "Pi extension observed agent_settled",
                    event_at,
                ));
            }
            Some("error") => {
                attention = Some((
                    AttentionState::Interrupted,
                    "Pi extension observed an agent error",
                    event_at,
                ));
            }
            Some("session_shutdown") => detached_at = event_at,
            _ => {}
        }
    }

    if saw_no_session_true && !saw_no_session_false {
        return None;
    }

    let mut snapshot = SessionSnapshot::new(
        AgentFamily::Pi,
        Surface::Cli,
        native_id?,
        cwd,
        "hook (Pi extension)".to_string(),
        last_source_activity_at.unwrap_or(fallback_source_activity_at),
    );
    snapshot.session_display_name = display_name;
    if let Some((state, evidence, at)) = attention {
        snapshot.set_attention(state, evidence, at);
    }
    if let Some(at) = detached_at {
        snapshot.set_session_liveness(
            SessionLiveness::Detached,
            "Pi extension observed session_shutdown",
            Some(at),
        );
    } else {
        snapshot.set_session_liveness(
            SessionLiveness::Unknown,
            "ordinary Pi TUI is not Observer-owned; LOST is not inferred",
            None,
        );
    }
    if let Some((process_id, started_at)) = process_identity {
        match observe_expected(process_id, started_at) {
            ProcessObservation::Alive => snapshot.set_host_liveness(
                HostLiveness::Alive,
                "Pi extension PID and process creation time are alive",
                now,
            ),
            ProcessObservation::Missing | ProcessObservation::CreationTimeMismatch { .. } => {
                snapshot.set_host_liveness(
                    HostLiveness::Dead,
                    "Pi extension host PID and creation time are no longer alive",
                    now,
                )
            }
            ProcessObservation::Unreachable(message) => snapshot.set_host_liveness(
                HostLiveness::Unreachable,
                format!("Pi extension host process could not be checked: {message}"),
                now,
            ),
        }
    }
    Some(snapshot)
}

fn collect_files(root: &Path, extension: &str, paths: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_files(&path, extension, paths);
        } else if path.extension().and_then(|value| value.to_str()) == Some(extension) {
            paths.push(path);
        }
    }
}

fn json_lines(text: &str) -> impl Iterator<Item = Value> + '_ {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
}

fn string_field(value: &Value, name: &str) -> Option<String> {
    value
        .get(name)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn pi_entry_timestamp(value: &Value) -> Option<SystemTime> {
    value
        .get("message")
        .and_then(|message| message.get("timestamp"))
        .and_then(Value::as_u64)
        .and_then(|value| system_time_from_unix_millis(u128::from(value)))
        .or_else(|| {
            value
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(parse_rfc3339_utc)
        })
}

fn update_latest(target: &mut Option<SystemTime>, candidate: Option<SystemTime>) {
    if let Some(candidate) = candidate {
        *target = Some(target.map_or(candidate, |current| current.max(candidate)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{EvidenceFreshness, unix_millis};

    fn at(raw: &str) -> SystemTime {
        parse_rfc3339_utc(raw).unwrap()
    }

    #[test]
    fn passive_pi_journal_preserves_native_unicode_name_without_false_green() {
        let text = r#"
{"type":"session","version":3,"id":"pi-1","timestamp":"2026-08-31T10:00:00Z","cwd":"D:\\work"}
{"type":"message","id":"a","parentId":null,"timestamp":"2026-08-31T10:00:01Z","message":{"role":"user","content":"redacted","timestamp":1788170401000}}
{"type":"message","id":"b","parentId":"a","timestamp":"2026-08-31T10:00:02Z","message":{"role":"assistant","content":[],"stopReason":"stop","timestamp":1788170402000}}
{"type":"session_info","id":"c","parentId":"b","timestamp":"2026-08-31T10:00:03Z","name":"修复中文标题"}
"#;
        let snapshot = parse_journal(text, at("2026-08-31T10:00:03Z")).unwrap();

        assert_eq!(snapshot.native_session_id, "pi-1");
        assert_eq!(snapshot.cwd.as_deref(), Some("D:\\work"));
        assert_eq!(
            snapshot.session_display_name.as_deref(),
            Some("修复中文标题")
        );
        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn unrelated_pi_session_info_does_not_refresh_attention_evidence() {
        let text = r#"
{"type":"session","version":3,"id":"pi-1","timestamp":"2026-08-31T10:00:00Z","cwd":"D:\\work"}
{"type":"message","id":"a","parentId":null,"timestamp":"2026-08-31T10:00:01Z","message":{"role":"user","content":"redacted","timestamp":1788170401000}}
{"type":"session_info","id":"b","parentId":"a","timestamp":"2026-08-31T10:10:00Z","name":"renamed"}
"#;
        let mut snapshot = parse_journal(text, at("2026-08-31T10:10:00Z")).unwrap();
        snapshot.apply_evidence_freshness(at("2026-08-31T10:10:00Z"), Duration::from_secs(300));

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Stale);
    }

    #[test]
    fn ordinary_pi_hook_never_marks_a_dead_host_lost() {
        let text = r#"{"observer_schema":1,"source":"pi-extension","event":"agent_start","session_id":"pi-2","cwd":"D:\\work","observed_at_unix_ms":1000,"process_id":4294967294,"process_started_at_unix_ms":1000}"#;
        let snapshot = parse_hook_log(text, SystemTime::UNIX_EPOCH, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn pi_agent_settled_is_the_completion_gate() {
        let text = concat!(
            "{\"observer_schema\":1,\"source\":\"pi-extension\",\"event\":\"agent_start\",\"session_id\":\"pi-3\",\"observed_at_unix_ms\":1000}\n",
            "{\"observer_schema\":1,\"source\":\"pi-extension\",\"event\":\"agent_settled\",\"session_id\":\"pi-3\",\"observed_at_unix_ms\":2000}\n"
        );
        let snapshot = parse_hook_log(text, SystemTime::UNIX_EPOCH, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
    }

    fn hook_record(session_id: &str, extra: &str) -> String {
        let extra = if extra.is_empty() {
            String::new()
        } else {
            format!(",{extra}")
        };
        format!(
            r#"{{"observer_schema":1,"source":"pi-extension","event":"agent_settled","session_id":"{session_id}","observed_at_unix_ms":1000{extra}}}"#
        )
    }

    fn parse_hook(text: &str) -> Option<SessionSnapshot> {
        parse_hook_log(text, SystemTime::UNIX_EPOCH, SystemTime::now())
    }

    fn hook_records(session_id: &str, extras: &[&str]) -> String {
        extras
            .iter()
            .map(|extra| hook_record(session_id, extra))
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn only_true_is_suppressed() {
        assert!(parse_hook(&hook_record("pi-ns", r#""no_session":true"#)).is_none());
    }

    #[test]
    fn true_then_missing_is_suppressed() {
        assert!(
            parse_hook(&hook_records(
                "pi-ns",
                &[r#""no_session":true"#, r#""mode":"print""#]
            ))
            .is_none()
        );
    }

    #[test]
    fn missing_then_true_is_suppressed() {
        assert!(
            parse_hook(&hook_records(
                "pi-ns",
                &[r#""mode":"print""#, r#""no_session":true"#]
            ))
            .is_none()
        );
    }

    #[test]
    fn false_then_true_is_kept() {
        let snapshot = parse_hook(&hook_records(
            "pi-mixed",
            &[r#""no_session":false"#, r#""no_session":true"#],
        ))
        .unwrap();
        assert_eq!(snapshot.native_session_id, "pi-mixed");
    }

    #[test]
    fn true_then_false_is_kept() {
        let snapshot = parse_hook(&hook_records(
            "pi-mixed",
            &[r#""no_session":true"#, r#""no_session":false"#],
        ))
        .unwrap();
        assert_eq!(snapshot.native_session_id, "pi-mixed");
    }

    #[test]
    fn repeated_true_is_suppressed() {
        assert!(
            parse_hook(&hook_records(
                "pi-ns",
                &[r#""no_session":true"#, r#""no_session":true"#]
            ))
            .is_none()
        );
    }

    #[test]
    fn repeated_false_is_kept() {
        let snapshot = parse_hook(&hook_records(
            "pi-keep",
            &[r#""no_session":false"#, r#""no_session":false"#],
        ))
        .unwrap();
        assert_eq!(snapshot.native_session_id, "pi-keep");
    }

    #[test]
    fn true_plus_null_without_false_is_suppressed() {
        assert!(
            parse_hook(&hook_records(
                "pi-ns",
                &[r#""no_session":true"#, r#""no_session":null"#]
            ))
            .is_none()
        );
    }

    #[test]
    fn false_plus_non_boolean_is_kept() {
        for value in [r#""true""#, "1", "null", r#"{"flag":true}"#] {
            let marker = format!(r#""no_session":{value}"#);
            assert!(
                parse_hook(&hook_records(
                    "pi-keep",
                    &[r#""no_session":false"#, &marker]
                ))
                .is_some()
            );
        }
    }

    #[test]
    fn mixed_marker_keeps_attention_snapshot() {
        let snapshot = parse_hook(&hook_records(
            "pi-mixed",
            &[r#""no_session":true"#, r#""no_session":false"#],
        ))
        .unwrap();
        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
    }

    #[test]
    fn old_missing_marker_hook_remains_visible() {
        let snapshot = parse_hook(&hook_record(
            "22222222-2222-4222-8222-222222222222",
            r#""mode":"print","cwd":"D:\\Pi Desktop""#,
        ))
        .expect("historical hook-only print invocations stay visible without no_session");
        assert_eq!(
            snapshot.native_session_id,
            "22222222-2222-4222-8222-222222222222"
        );
        assert_eq!(snapshot.cwd.as_deref(), Some(r"D:\Pi Desktop"));
        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
    }

    #[test]
    fn non_boolean_no_session_values_are_not_suppressed() {
        for extra in [
            r#""no_session":"true""#,
            r#""no_session":1"#,
            r#""no_session":null"#,
            r#""no_session":{"flag":true}"#,
        ] {
            assert!(parse_hook(&hook_record("pi-nonbool", extra)).is_some());
        }
    }

    #[test]
    fn mixed_marker_never_hides_same_id_journal() {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-pi-mixed-journal-{}-{}",
            std::process::id(),
            unix_millis(SystemTime::now())
        ));
        let sessions = root.join("sessions");
        let hooks = root.join("hooks");
        fs::create_dir_all(&sessions).unwrap();
        fs::create_dir_all(&hooks).unwrap();
        fs::write(
            sessions.join("shared.jsonl"),
            concat!(
                r#"{"type":"session","version":3,"id":"pi-shared-mixed","timestamp":"2026-09-02T10:00:00Z","cwd":"D:\\work"}"#,
                "\n",
                r#"{"type":"session_info","id":"n","timestamp":"2026-09-02T10:00:01Z","name":"同ID期刊"}"#,
                "\n"
            ),
        )
        .unwrap();
        fs::write(
            hooks.join("shared.jsonl"),
            hook_records(
                "pi-shared-mixed",
                &[r#""no_session":true"#, r#""no_session":false"#],
            ),
        )
        .unwrap();

        let snapshots = discover(
            &sessions,
            &hooks,
            SystemTime::now(),
            Duration::from_secs(300),
            true,
        );
        assert!(snapshots.iter().any(|snapshot| {
            snapshot.native_session_id == "pi-shared-mixed"
                && snapshot.source == "pi-journal (passive)"
                && snapshot.session_display_name.as_deref() == Some("同ID期刊")
        }));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn discover_keeps_journals_and_ordinary_hooks_while_dropping_explicit_no_session() {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-pi-no-session-{}-{}",
            std::process::id(),
            unix_millis(SystemTime::now())
        ));
        let sessions = root.join("sessions");
        let hooks = root.join("hooks");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&sessions).unwrap();
        fs::create_dir_all(&hooks).unwrap();

        fs::write(
            sessions.join("persistent.jsonl"),
            concat!(
                r#"{"type":"session","version":3,"id":"pi-journal-keep","timestamp":"2026-09-02T10:00:00Z","cwd":"D:\\work"}"#,
                "\n",
                r#"{"type":"session_info","id":"n","timestamp":"2026-09-02T10:00:01Z","name":"持久会话"}"#,
                "\n"
            ),
        )
        .unwrap();
        fs::write(
            sessions.join("shared-id.jsonl"),
            concat!(
                r#"{"type":"session","version":3,"id":"pi-shared","timestamp":"2026-09-02T10:00:00Z","cwd":"D:\\work"}"#,
                "\n",
                r#"{"type":"session_info","id":"n","timestamp":"2026-09-02T10:00:01Z","name":"同ID期刊"}"#,
                "\n"
            ),
        )
        .unwrap();
        fs::write(
            hooks.join("no-session.jsonl"),
            hook_record(
                "pi-ns-drop",
                r#""no_session":true,"mode":"print","cwd":"D:\\Pi Desktop""#,
            ),
        )
        .unwrap();
        fs::write(
            hooks.join("shared-no-session.jsonl"),
            hook_record("pi-shared", r#""no_session":true"#),
        )
        .unwrap();
        fs::write(
            hooks.join("ordinary.jsonl"),
            hook_record(
                "pi-hook-keep",
                r#""no_session":false,"mode":"rpc","cwd":"D:\\work""#,
            ),
        )
        .unwrap();
        fs::write(
            hooks.join("historical-print.jsonl"),
            hook_record(
                "22222222-2222-4222-8222-222222222222",
                r#""mode":"print","cwd":"D:\\Pi Desktop""#,
            ),
        )
        .unwrap();
        fs::write(
            hooks.join("cli-print.jsonl"),
            hook_record(
                "pi-cli-print",
                r#""no_session":false,"mode":"print","cwd":"D:\\work""#,
            ),
        )
        .unwrap();

        let snapshots = discover(
            &sessions,
            &hooks,
            SystemTime::now(),
            Duration::from_secs(300),
            true,
        );
        let ids: Vec<&str> = snapshots
            .iter()
            .map(|snapshot| snapshot.native_session_id.as_str())
            .collect();

        assert!(
            ids.contains(&"pi-journal-keep"),
            "missing journal in {ids:?}"
        );
        assert!(
            ids.contains(&"pi-hook-keep"),
            "missing ordinary hook in {ids:?}"
        );
        assert!(
            ids.contains(&"pi-cli-print"),
            "CLI print without --no-session must remain visible: {ids:?}"
        );
        assert!(
            ids.contains(&"22222222-2222-4222-8222-222222222222"),
            "historical hook without no_session must remain visible: {ids:?}"
        );
        assert!(
            ids.contains(&"pi-shared"),
            "journal with the same id as a no_session hook must remain: {ids:?}"
        );
        assert!(
            !ids.contains(&"pi-ns-drop"),
            "explicit no_session hook must not be discovered: {ids:?}"
        );
        let shared = snapshots
            .iter()
            .find(|snapshot| snapshot.native_session_id == "pi-shared")
            .unwrap();
        assert_eq!(shared.source, "pi-journal (passive)");
        assert_eq!(shared.session_display_name.as_deref(), Some("同ID期刊"));

        let _ = fs::remove_dir_all(root);
    }
}
