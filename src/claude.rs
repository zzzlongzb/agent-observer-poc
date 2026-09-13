use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::model::{
    AgentFamily, AttentionState, SessionSnapshot, Surface, parse_rfc3339_utc,
    presentation_session_name,
};

pub fn discover(
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let mut paths = Vec::new();
    collect_journals(root, &mut paths);

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

fn collect_journals(root: &Path, paths: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_journals(&path, paths);
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
    let source_activity_at = metadata.modified().ok()?;
    let source_age = now
        .duration_since(source_activity_at)
        .unwrap_or(Duration::ZERO);
    if !include_stale && source_age > stale_after {
        return None;
    }

    let text = fs::read_to_string(path).ok()?;
    let mut snapshot = parse_journal(path, &text, source_activity_at)?;
    snapshot.apply_evidence_freshness(now, stale_after);
    Some(snapshot)
}

fn parse_journal(
    path: &Path,
    text: &str,
    source_activity_at: SystemTime,
) -> Option<SessionSnapshot> {
    let mut native_id = None;
    let mut cwd = None;
    let mut entrypoint = None;
    let mut attention_state = AttentionState::Unknown;
    let mut attention_evidence = "no explicit Claude lifecycle state in journal".to_string();
    let mut last_attention_evidence_at = None;
    let mut saw_primary_record = false;
    let mut active_background_tasks = BTreeSet::new();
    let mut custom_title = None;
    let mut ai_title = None;

    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if value.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        saw_primary_record = true;

        native_id = value
            .get("sessionId")
            .or_else(|| value.get("session_id"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or(native_id);
        cwd = value
            .get("cwd")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or(cwd);
        entrypoint = value
            .get("entrypoint")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or(entrypoint);

        match value.get("type").and_then(Value::as_str) {
            Some("custom-title") => {
                if let Some(name) = value
                    .get("customTitle")
                    .and_then(Value::as_str)
                    .and_then(presentation_session_name)
                {
                    custom_title = Some(name);
                }
            }
            Some("ai-title") => {
                if let Some(name) = value
                    .get("aiTitle")
                    .and_then(Value::as_str)
                    .and_then(presentation_session_name)
                {
                    ai_title = Some(name);
                }
            }
            _ => {}
        }

        let timestamp = journal_timestamp(&value);
        if let Some((task_id, status)) = background_task_notification(&value)
            && background_task_terminal(&status)
        {
            active_background_tasks.remove(&task_id);
        }
        if let Some(task_id) = background_task_id(&value) {
            active_background_tasks.insert(task_id.to_string());
            attention_state = AttentionState::Working;
            attention_evidence =
                "heuristic: Claude background task was started; completion is not yet journaled"
                    .to_string();
            last_attention_evidence_at = timestamp;
        } else if let Some(raw_state) = value
            .get("status")
            .or_else(|| value.get("state"))
            .and_then(Value::as_str)
        {
            attention_state = explicit_attention(raw_state);
            attention_evidence = format!("journal status/state: {raw_state}");
            last_attention_evidence_at = timestamp;
        } else if !active_background_tasks.is_empty() && completed_assistant_turn(&value) {
            // Claude Desktop can acknowledge the parent turn while its tool is
            // still registered as a background task. A journal transcript has
            // not yet provided a durable completion record for every child.
            attention_state = AttentionState::Working;
            attention_evidence =
                "heuristic: Claude background task has no completion record".to_string();
            last_attention_evidence_at = timestamp;
        } else if let Some((next_attention, evidence)) = heuristic_attention(&value) {
            attention_state = next_attention;
            attention_evidence = evidence.to_string();
            last_attention_evidence_at = timestamp;
        }
    }

    if !saw_primary_record {
        return None;
    }

    let inferred_from_filename = native_id.is_none();
    let native_session_id = native_id.or_else(|| {
        path.file_stem()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
    })?;
    let surface = surface_from_entrypoint(entrypoint.as_deref());
    let source = match (entrypoint, inferred_from_filename) {
        (Some(entrypoint), false) => format!("journal (entrypoint: {entrypoint})"),
        (Some(entrypoint), true) => {
            format!("journal (entrypoint: {entrypoint}; id inferred from filename)")
        }
        (None, true) => "journal (id inferred from filename)".to_string(),
        (None, false) => "journal".to_string(),
    };

    let mut snapshot = SessionSnapshot::new(
        AgentFamily::Claude,
        surface,
        native_session_id,
        cwd,
        source,
        source_activity_at,
    );
    snapshot.set_attention(
        attention_state,
        attention_evidence,
        last_attention_evidence_at,
    );
    snapshot.session_display_name = custom_title.or(ai_title);
    Some(snapshot)
}

fn journal_timestamp(value: &Value) -> Option<SystemTime> {
    value
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339_utc)
}

fn background_task_id(value: &Value) -> Option<&str> {
    value
        .get("toolUseResult")
        .and_then(|result| result.get("backgroundTaskId"))
        .and_then(Value::as_str)
}

fn background_task_notification(value: &Value) -> Option<(String, String)> {
    let text = match value.get("type").and_then(Value::as_str) {
        Some("queue-operation") => value.get("content").and_then(Value::as_str),
        Some("attachment") => value
            .get("attachment")
            .filter(|attachment| {
                attachment.get("type").and_then(Value::as_str) == Some("queued_command")
                    && attachment.get("commandMode").and_then(Value::as_str)
                        == Some("task-notification")
            })
            .and_then(|attachment| attachment.get("prompt"))
            .and_then(Value::as_str),
        _ => None,
    }?;
    Some((
        text_between(text, "<task-id>", "</task-id>")?.to_string(),
        text_between(text, "<status>", "</status>")?.to_string(),
    ))
}

fn text_between<'a>(text: &'a str, start: &str, end: &str) -> Option<&'a str> {
    let value = text.split_once(start)?.1.split_once(end)?.0.trim();
    (!value.is_empty()).then_some(value)
}

fn background_task_terminal(status: &str) -> bool {
    matches!(
        status.to_ascii_lowercase().as_str(),
        "completed" | "failed" | "cancelled" | "canceled" | "killed" | "terminated" | "error"
    )
}

fn completed_assistant_turn(value: &Value) -> bool {
    value.get("type").and_then(Value::as_str) == Some("assistant")
        && value
            .get("message")
            .and_then(|message| message.get("stop_reason"))
            .and_then(Value::as_str)
            .is_some_and(|reason| reason == "end_turn" || reason == "stop_sequence")
}

fn heuristic_attention(value: &Value) -> Option<(AttentionState, &'static str)> {
    let record_type = value.get("type").and_then(Value::as_str)?;
    match record_type {
        "user" if user_rejected_tool_use(value) => Some((
            AttentionState::NeedsMe,
            "heuristic: user rejected a tool use; agent awaits next instruction",
        )),
        "user" => Some((
            AttentionState::Working,
            "heuristic: latest user journal record awaits agent work",
        )),
        "assistant" => {
            let message = value.get("message").unwrap_or(value);
            match message.get("stop_reason").and_then(Value::as_str) {
                Some("end_turn") | Some("stop_sequence") => Some((
                    AttentionState::ResultReady,
                    "heuristic: assistant stop_reason indicates a completed turn",
                )),
                Some(_) | None => Some((
                    AttentionState::Working,
                    "heuristic: assistant journal record without completed stop_reason",
                )),
            }
        }
        _ => None,
    }
}

fn user_rejected_tool_use(value: &Value) -> bool {
    if value.get("toolDenialKind").and_then(Value::as_str) == Some("user-rejected") {
        return true;
    }

    let Some(content) = value
        .get("message")
        .and_then(|message| message.get("content"))
    else {
        return false;
    };

    match content {
        Value::String(text) => text.contains("[Request interrupted by user for tool use]"),
        Value::Array(items) => items.iter().any(|item| {
            (item.get("type").and_then(Value::as_str) == Some("tool_result")
                && item
                    .get("content")
                    .and_then(Value::as_str)
                    .is_some_and(|text| text.contains("The user doesn't want to proceed")))
                || (item.get("type").and_then(Value::as_str) == Some("text")
                    && item
                        .get("text")
                        .and_then(Value::as_str)
                        .is_some_and(|text| {
                            text.contains("[Request interrupted by user for tool use]")
                        }))
        }),
        _ => false,
    }
}

fn explicit_attention(raw: &str) -> AttentionState {
    match raw.to_ascii_lowercase().as_str() {
        "thinking" | "working" | "running" | "tool_use" => AttentionState::Working,
        "awaiting_approval" | "permission" | "needs_permission" | "waiting" => {
            AttentionState::NeedsMe
        }
        "done" | "completed" => AttentionState::ResultReady,
        "error" | "failed" | "aborted" => AttentionState::Interrupted,
        _ => AttentionState::Unknown,
    }
}

fn surface_from_entrypoint(entrypoint: Option<&str>) -> Surface {
    match entrypoint {
        Some("claude-desktop") => Surface::Desktop,
        Some("cli") | Some("sdk-cli") => Surface::Cli,
        _ => Surface::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::EvidenceFreshness;

    fn timestamp(raw: &str) -> SystemTime {
        parse_rfc3339_utc(raw).unwrap()
    }

    #[test]
    fn reads_claude_desktop_identity() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"user","sessionId":"desktop-1","cwd":"D:\\ProjectA","entrypoint":"claude-desktop","message":{"role":"user","content":"hello"}}
{"timestamp":"2026-08-26T10:00:01Z","type":"assistant","sessionId":"desktop-1","message":{"stop_reason":"end_turn"}}
"#;

        let snapshot = parse_journal(
            Path::new("desktop.jsonl"),
            journal,
            timestamp("2026-08-26T10:00:02Z"),
        )
        .unwrap();

        assert_eq!(snapshot.surface, Surface::Desktop);
        assert_eq!(snapshot.native_session_id, "desktop-1");
        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.session_display_name, None);
    }

    #[test]
    fn reads_cli_and_explicit_permission_attention() {
        let journal = r#"{"timestamp":"2026-08-26T10:00:00Z","type":"system","sessionId":"cli-1","cwd":"D:\\ProjectA","entrypoint":"cli","status":"needs_permission"}"#;

        let snapshot = parse_journal(Path::new("cli.jsonl"), journal, SystemTime::now()).unwrap();

        assert_eq!(snapshot.surface, Surface::Cli);
        assert_eq!(snapshot.attention_state, AttentionState::NeedsMe);
    }

    #[test]
    fn recognizes_the_current_sdk_cli_entrypoint() {
        let journal = r#"{"type":"system","sessionId":"cli-sdk-1","entrypoint":"sdk-cli"}"#;

        let snapshot =
            parse_journal(Path::new("cli-sdk.jsonl"), journal, SystemTime::now()).unwrap();

        assert_eq!(snapshot.surface, Surface::Cli);
    }

    #[test]
    fn ignores_sidechain_records() {
        let journal = r#"{"type":"assistant","isSidechain":true,"sessionId":"child"}"#;
        assert!(parse_journal(Path::new("child.jsonl"), journal, SystemTime::now()).is_none());
    }

    #[test]
    fn recognizes_a_user_rejected_tool_as_needing_new_input() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"assistant","sessionId":"cli-2","cwd":"D:\\ProjectA","entrypoint":"cli","message":{"stop_reason":"tool_use"}}
{"timestamp":"2026-08-26T10:00:01Z","type":"user","sessionId":"cli-2","toolDenialKind":"user-rejected","message":{"content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use."}]}}
"#;

        let snapshot = parse_journal(Path::new("cli-2.jsonl"), journal, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::NeedsMe);
        assert!(snapshot.attention_evidence.contains("rejected a tool use"));
    }

    #[test]
    fn keeps_a_claude_desktop_background_task_working_after_end_turn() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"assistant","sessionId":"desktop-bg","cwd":"D:\\ProjectA","entrypoint":"claude-desktop","message":{"stop_reason":"tool_use","content":[{"type":"tool_use"}]}}
{"timestamp":"2026-08-26T10:00:01Z","type":"user","sessionId":"desktop-bg","toolUseResult":{"interrupted":false,"backgroundTaskId":"task-1"},"message":{"content":[{"type":"tool_result"}]}}
{"timestamp":"2026-08-26T10:00:02Z","type":"assistant","sessionId":"desktop-bg","message":{"stop_reason":"end_turn","content":[{"type":"text"}]}}
"#;

        let snapshot = parse_journal(
            Path::new("desktop-background.jsonl"),
            journal,
            SystemTime::now(),
        )
        .unwrap();

        assert_eq!(snapshot.surface, Surface::Desktop);
        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert!(snapshot.attention_evidence.contains("background task"));
    }

    #[test]
    fn completed_background_task_allows_a_later_end_turn_to_be_result_ready() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"user","sessionId":"desktop-bg-complete","cwd":"D:\\ProjectA","entrypoint":"claude-desktop","toolUseResult":{"backgroundTaskId":"task-1"}}
{"timestamp":"2026-08-26T10:00:01Z","type":"assistant","sessionId":"desktop-bg-complete","message":{"stop_reason":"end_turn"}}
{"timestamp":"2026-08-26T10:00:02Z","type":"queue-operation","operation":"enqueue","sessionId":"desktop-bg-complete","content":"<task-notification><task-id>task-1</task-id><status>completed</status></task-notification>"}
{"timestamp":"2026-08-26T10:00:03Z","type":"assistant","sessionId":"desktop-bg-complete","message":{"stop_reason":"end_turn"}}
"#;

        let snapshot = parse_journal(
            Path::new("desktop-background-complete.jsonl"),
            journal,
            SystemTime::now(),
        )
        .unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshot.attention_evidence,
            "heuristic: assistant stop_reason indicates a completed turn"
        );
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(timestamp("2026-08-26T10:00:03Z"))
        );
    }

    #[test]
    fn completion_for_another_background_task_does_not_false_green() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"user","sessionId":"desktop-bg-other","cwd":"D:\\ProjectA","entrypoint":"claude-desktop","toolUseResult":{"backgroundTaskId":"task-1"}}
{"timestamp":"2026-08-26T10:00:01Z","type":"queue-operation","operation":"enqueue","sessionId":"desktop-bg-other","content":"<task-notification><task-id>task-2</task-id><status>completed</status></task-notification>"}
{"timestamp":"2026-08-26T10:00:02Z","type":"assistant","sessionId":"desktop-bg-other","message":{"stop_reason":"end_turn"}}
"#;

        let snapshot = parse_journal(
            Path::new("desktop-background-other.jsonl"),
            journal,
            SystemTime::now(),
        )
        .unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert!(snapshot.attention_evidence.contains("background task"));
    }

    #[test]
    fn journal_source_activity_does_not_make_an_old_attention_event_fresh() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"user","sessionId":"cli-1","entrypoint":"cli"}
{"timestamp":"2026-08-26T11:00:00Z","type":"custom-title","sessionId":"cli-1"}
"#;
        let now = timestamp("2026-08-26T11:00:00Z");
        let mut snapshot = parse_journal(Path::new("cli.jsonl"), journal, now).unwrap();
        snapshot.apply_evidence_freshness(now, Duration::from_secs(300));

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Stale);
        assert_eq!(snapshot.session_display_name, None);
    }

    #[test]
    fn prefers_native_custom_title_over_ai_title() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"user","sessionId":"cli-title","cwd":"D:\\ProjectA","entrypoint":"cli","message":{"role":"user"}}
{"type":"ai-title","sessionId":"cli-title","aiTitle":"Runtime binding acceptance"}
{"type":"custom-title","sessionId":"cli-title","customTitle":"Fix quota reset jitter"}
"#;

        let snapshot =
            parse_journal(Path::new("cli-title.jsonl"), journal, SystemTime::now()).unwrap();

        assert_eq!(
            snapshot.session_display_name.as_deref(),
            Some("Fix quota reset jitter")
        );
        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.native_session_id, "cli-title");
        assert_eq!(snapshot.cwd.as_deref(), Some("D:\\ProjectA"));
    }

    #[test]
    fn uses_native_ai_title_when_custom_title_is_absent() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"assistant","sessionId":"cli-ai","cwd":"D:\\ProjectA","entrypoint":"cli","message":{"stop_reason":"end_turn"}}
{"type":"ai-title","sessionId":"cli-ai","aiTitle":"Review trading annotations"}
"#;

        let snapshot =
            parse_journal(Path::new("cli-ai.jsonl"), journal, SystemTime::now()).unwrap();

        assert_eq!(
            snapshot.session_display_name.as_deref(),
            Some("Review trading annotations")
        );
        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
    }

    #[test]
    fn rejects_path_like_native_titles() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"user","sessionId":"cli-path","cwd":"D:\\synthetic-workspace","entrypoint":"cli"}
{"type":"custom-title","sessionId":"cli-path","customTitle":"D:\\synthetic-workspace"}
{"type":"ai-title","sessionId":"cli-path","aiTitle":"/home/user/project"}
"#;

        let snapshot =
            parse_journal(Path::new("cli-path.jsonl"), journal, SystemTime::now()).unwrap();

        assert_eq!(snapshot.session_display_name, None);
        assert_eq!(snapshot.cwd.as_deref(), Some("D:\\synthetic-workspace"));
        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }
}
