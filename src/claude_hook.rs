use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::model::{
    AgentFamily, AttentionState, SessionLiveness, SessionSnapshot, Surface, parse_rfc3339_utc,
};

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
    let mut surface = None;
    let mut runtime_binding_id = None;
    let mut active_runtime_id = None;
    let mut attention = None;
    let mut session_liveness = None;
    let mut last_source_activity_at = None;

    for line in text
        .lines()
        .map(|line| line.trim().trim_start_matches('\u{feff}'))
        .filter(|line| !line.is_empty())
    {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if !supported_schema(&value) {
            continue;
        }

        let event_at = hook_timestamp(&value);
        if let Some(event_at) = event_at {
            last_source_activity_at = Some(
                last_source_activity_at
                    .map(|current: SystemTime| current.max(event_at))
                    .unwrap_or(event_at),
            );
        }
        native_id = value
            .get("session_id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or(native_id);
        cwd = value
            .get("cwd")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or(cwd);
        if let Some(id) = value
            .get("runtime_binding_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            runtime_binding_id = Some(id.to_string());
        }
        if let Some(id) = value
            .get("prompt_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            active_runtime_id = Some(id.to_string());
        }
        surface = hook_surface(&value).or(surface);

        let Some(event) = value
            .get("hook_event_name")
            .or_else(|| value.get("event"))
            .and_then(Value::as_str)
        else {
            continue;
        };
        let update = state_from_hook_event(event, &value);
        if let Some((next_attention, evidence)) = update.attention {
            attention = Some((next_attention, evidence.to_string(), event_at));
        }
        if let Some((next_liveness, evidence)) = update.session_liveness {
            session_liveness = Some((next_liveness, evidence.to_string(), event_at));
        }
        if matches!(update.attention, Some((AttentionState::ResultReady, _)))
            || matches!(
                update.session_liveness,
                Some((SessionLiveness::Detached, _))
            )
        {
            active_runtime_id = None;
        }
    }

    let inferred_from_filename = native_id.is_none();
    let native_session_id = native_id.or_else(|| {
        path.file_stem()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
    })?;
    let surface = surface.unwrap_or(Surface::Cli);
    let source = if inferred_from_filename {
        format!("hook (surface: {surface}; id inferred from filename)")
    } else {
        format!("hook (surface: {surface})")
    };
    let mut snapshot = SessionSnapshot::new(
        AgentFamily::Claude,
        surface,
        native_session_id,
        cwd,
        source,
        last_source_activity_at.unwrap_or(fallback_source_activity_at),
    );
    if let Some((state, evidence, observed_at)) = attention {
        snapshot.set_attention(state, evidence, observed_at);
    }
    if let Some((liveness, evidence, observed_at)) = session_liveness {
        snapshot.set_session_liveness(liveness, evidence, observed_at);
    }
    snapshot.runtime_binding_id = runtime_binding_id;
    snapshot.active_runtime_id = active_runtime_id;
    Some(snapshot)
}

fn supported_schema(value: &Value) -> bool {
    matches!(
        value.get("observer_schema").and_then(Value::as_u64),
        Some(1 | 2)
    )
}

fn hook_timestamp(value: &Value) -> Option<SystemTime> {
    value
        .get("observed_at_utc")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339_utc)
}

fn hook_surface(value: &Value) -> Option<Surface> {
    match value.get("surface").and_then(Value::as_str) {
        Some(value) if value.eq_ignore_ascii_case("desktop") => Some(Surface::Desktop),
        Some(value) if value.eq_ignore_ascii_case("cli") => Some(Surface::Cli),
        Some(value) if value.eq_ignore_ascii_case("unknown") => Some(Surface::Unknown),
        _ => None,
    }
}

struct HookUpdate {
    attention: Option<(AttentionState, &'static str)>,
    session_liveness: Option<(SessionLiveness, &'static str)>,
}

impl HookUpdate {
    fn attention(state: AttentionState, evidence: &'static str) -> Self {
        Self {
            attention: Some((state, evidence)),
            session_liveness: None,
        }
    }

    fn attention_and_liveness(
        state: AttentionState,
        attention_evidence: &'static str,
        liveness: SessionLiveness,
        liveness_evidence: &'static str,
    ) -> Self {
        Self {
            attention: Some((state, attention_evidence)),
            session_liveness: Some((liveness, liveness_evidence)),
        }
    }

    fn liveness(liveness: SessionLiveness, evidence: &'static str) -> Self {
        Self {
            attention: None,
            session_liveness: Some((liveness, evidence)),
        }
    }

    fn none() -> Self {
        Self {
            attention: None,
            session_liveness: None,
        }
    }
}

fn state_from_hook_event(event: &str, value: &Value) -> HookUpdate {
    match event {
        "SessionStart" => HookUpdate::liveness(
            SessionLiveness::LiveIdle,
            "hook: Claude session lifecycle started",
        ),
        "UserPromptSubmit"
        | "UserPromptExpansion"
        | "PreToolUse"
        | "PostToolUse"
        | "PostToolUseFailure"
        | "PostToolBatch" => HookUpdate::attention_and_liveness(
            AttentionState::Working,
            "hook: Claude is processing work",
            SessionLiveness::LiveActive,
            "hook: active Claude prompt or tool lifecycle event",
        ),
        "Notification" | "PermissionRequest" | "Elicitation" => HookUpdate::attention_and_liveness(
            AttentionState::NeedsMe,
            "hook: Claude needs user attention",
            SessionLiveness::LiveIdle,
            "hook: Claude is waiting for user attention",
        ),
        "PermissionDenied" => HookUpdate::attention_and_liveness(
            AttentionState::Interrupted,
            "hook: Claude auto-mode permission denial",
            SessionLiveness::LiveIdle,
            "hook: Claude delivered a terminal permission decision",
        ),
        "StopFailure" => HookUpdate::attention_and_liveness(
            AttentionState::Interrupted,
            "hook: Claude stop failed",
            SessionLiveness::LiveIdle,
            "hook: Claude delivered StopFailure",
        ),
        "Stop" => stop_update(value),
        "SessionEnd" => HookUpdate::liveness(
            SessionLiveness::Detached,
            "hook: Claude SessionEnd detached the current runtime",
        ),
        _ => HookUpdate::none(),
    }
}

fn stop_update(value: &Value) -> HookUpdate {
    match background_work(value) {
        BackgroundWork::Active => HookUpdate::attention_and_liveness(
            AttentionState::Working,
            "hook: Claude Stop reported active background work",
            SessionLiveness::LiveActive,
            "hook: Claude Stop reported background_tasks or session_crons",
        ),
        BackgroundWork::Empty => HookUpdate::attention_and_liveness(
            AttentionState::ResultReady,
            "hook: Claude Stop reported no background work",
            SessionLiveness::LiveIdle,
            "hook: Claude Stop reported an idle session",
        ),
        BackgroundWork::Unknown => HookUpdate::attention(
            AttentionState::Working,
            "hook: Claude Stop lacked complete background work evidence; completion not assumed",
        ),
    }
}

enum BackgroundWork {
    Active,
    Empty,
    Unknown,
}

fn background_work(value: &Value) -> BackgroundWork {
    let background_active = collection_has_items(value.get("background_tasks"));
    let crons_active = collection_has_items(value.get("session_crons"));

    if background_active || crons_active {
        BackgroundWork::Active
    } else if collection_is_known_empty(value, "background_tasks")
        && collection_is_known_empty(value, "session_crons")
    {
        BackgroundWork::Empty
    } else {
        BackgroundWork::Unknown
    }
}

fn collection_is_known_empty(value: &Value, field: &str) -> bool {
    let present = value
        .get(&format!("{field}_present"))
        .and_then(Value::as_bool)
        .unwrap_or_else(|| value.get(field).is_some());
    present && matches!(value.get(field), Some(Value::Array(items)) if items.is_empty())
}

fn collection_has_items(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::Object(items)) => !items.is_empty(),
        Some(Value::String(item)) => !item.is_empty(),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::EvidenceFreshness;

    #[test]
    fn hook_lifecycle_identifies_a_cli_session_and_live_active_work() {
        let events = r#"
{"observer_schema":2,"surface":"cli","session_id":"cli-1","cwd":"D:\\ProjectA","hook_event_name":"SessionStart","observed_at_utc":"2026-08-26T10:00:00Z"}
{"observer_schema":2,"surface":"cli","session_id":"cli-1","cwd":"D:\\ProjectA","prompt_id":"prompt-1","tool_use_id":"tool-1","hook_event_name":"PreToolUse","observed_at_utc":"2026-08-26T10:00:01Z"}
"#;

        let snapshot =
            parse_event_log(Path::new("cli-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.surface, Surface::Cli);
        assert_eq!(snapshot.native_session_id, "cli-1");
        assert_eq!(snapshot.cwd.as_deref(), Some("D:\\ProjectA"));
        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveActive);
        assert!(snapshot.source.starts_with("hook (surface: CLI)"));
    }

    #[test]
    fn hook_records_runtime_binding_and_prompt_ids_for_exact_binding() {
        let events = r#"
{"observer_schema":2,"surface":"cli","runtime_binding_id":"bind-9","session_id":"cli-9","prompt_id":"prompt-9","cwd":"D:\\ws","hook_event_name":"UserPromptSubmit","observed_at_utc":"2026-08-26T10:00:00Z"}
"#;
        let snapshot =
            parse_event_log(Path::new("cli-9.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.runtime_binding_id.as_deref(), Some("bind-9"));
        assert_eq!(snapshot.active_runtime_id.as_deref(), Some("prompt-9"));
        assert_eq!(snapshot.native_session_id, "cli-9");
    }

    #[test]
    fn completed_stop_and_session_end_clear_active_prompt() {
        let events = r#"
{"observer_schema":2,"surface":"cli","runtime_binding_id":"bind-9","session_id":"cli-9","prompt_id":"prompt-9","hook_event_name":"UserPromptSubmit","observed_at_utc":"2026-08-26T10:00:00Z"}
{"observer_schema":2,"surface":"cli","runtime_binding_id":"bind-9","session_id":"cli-9","prompt_id":"prompt-9","hook_event_name":"Stop","background_tasks_present":true,"background_tasks":[],"session_crons_present":true,"session_crons":[],"observed_at_utc":"2026-08-26T10:00:01Z"}
{"observer_schema":2,"surface":"cli","runtime_binding_id":"bind-9","session_id":"cli-9","hook_event_name":"SessionEnd","observed_at_utc":"2026-08-26T10:00:02Z"}
"#;
        let snapshot =
            parse_event_log(Path::new("cli-9.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.runtime_binding_id.as_deref(), Some("bind-9"));
        assert_eq!(snapshot.active_runtime_id, None);
        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Detached);
    }

    #[test]
    fn claude_stop_with_empty_background_work_is_result_ready_and_idle() {
        let events = r#"{"observer_schema":2,"surface":"cli","session_id":"empty-1","hook_event_name":"Stop","background_tasks_present":true,"background_tasks":[],"session_crons_present":true,"session_crons":[],"observed_at_utc":"2026-08-26T10:00:00Z"}"#;

        let snapshot =
            parse_event_log(Path::new("empty-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveIdle);
    }

    #[test]
    fn claude_stop_with_active_background_work_does_not_false_green() {
        let events = r#"{"observer_schema":2,"surface":"cli","session_id":"background-1","hook_event_name":"Stop","background_tasks_present":true,"background_tasks":[{"task_id":"task-1"}],"session_crons_present":true,"session_crons":[],"observed_at_utc":"2026-08-26T10:00:00Z"}"#;

        let snapshot =
            parse_event_log(Path::new("background-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveActive);
        assert!(!snapshot.attention_evidence.contains("completed"));
    }

    #[test]
    fn claude_stop_with_redacted_background_task_metadata_stays_working() {
        let events = r#"{"observer_schema":2,"surface":"cli","session_id":"redacted-1","hook_event_name":"Stop","background_tasks_present":true,"background_tasks":[{"id":"b6v2o79cc","type":"shell","status":"running"}],"session_crons_present":true,"session_crons":[],"observed_at_utc":"2026-08-26T12:36:03Z"}"#;

        let snapshot =
            parse_event_log(Path::new("redacted-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveActive);
        assert!(
            snapshot
                .attention_evidence
                .contains("active background work")
        );
    }

    #[test]
    fn legacy_stop_without_background_fields_is_not_assumed_complete() {
        let events = r#"{"observer_schema":1,"session_id":"legacy-1","hook_event_name":"Stop","observed_at_utc":"2026-08-26T10:00:00Z"}"#;

        let snapshot =
            parse_event_log(Path::new("legacy-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn stop_with_null_background_fields_is_not_assumed_complete() {
        let events = r#"{"observer_schema":2,"surface":"cli","session_id":"null-1","hook_event_name":"Stop","background_tasks_present":true,"background_tasks":null,"session_crons_present":true,"session_crons":[],"observed_at_utc":"2026-08-26T10:00:00Z"}"#;

        let snapshot =
            parse_event_log(Path::new("null-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn session_end_detaches_without_hiding_a_prior_stop_failure() {
        let events = r#"
{"observer_schema":2,"surface":"cli","session_id":"cli-2","hook_event_name":"StopFailure","observed_at_utc":"2026-08-26T10:00:00Z"}
{"observer_schema":2,"surface":"cli","session_id":"cli-2","hook_event_name":"SessionEnd","observed_at_utc":"2026-08-26T10:00:01Z"}
"#;

        let snapshot =
            parse_event_log(Path::new("cli-2.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Interrupted);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Detached);
    }

    #[test]
    fn accepts_the_utf8_bom_written_by_windows_powershell() {
        let events = "\u{feff}{\"observer_schema\":2,\"surface\":\"cli\",\"session_id\":\"bom-1\",\"cwd\":\"C:/ProjectA\",\"hook_event_name\":\"Notification\",\"observed_at_utc\":\"2026-08-26T10:00:00Z\"}";

        let snapshot =
            parse_event_log(Path::new("bom-1.jsonl"), events, SystemTime::now()).unwrap();

        assert_eq!(snapshot.native_session_id, "bom-1");
        assert_eq!(snapshot.attention_state, AttentionState::NeedsMe);
    }

    #[test]
    fn uses_the_hook_timestamp_for_attention_and_source_activity() {
        let events = r#"{"observer_schema":2,"surface":"cli","session_id":"time-1","hook_event_name":"Stop","background_tasks_present":true,"background_tasks":[],"session_crons_present":true,"session_crons":[],"observed_at_utc":"1970-01-01T00:00:01.1234567Z"}"#;

        let snapshot =
            parse_event_log(Path::new("time-1.jsonl"), events, SystemTime::now()).unwrap();
        let expected = SystemTime::UNIX_EPOCH + Duration::new(1, 123_456_700);

        assert_eq!(snapshot.last_attention_evidence_at, Some(expected));
        assert_eq!(snapshot.last_source_activity_at, expected);
        assert_eq!(snapshot.session_liveness, SessionLiveness::LiveIdle);
    }

    #[test]
    fn stale_hook_evidence_does_not_change_attention_or_host_state() {
        let events = r#"{"observer_schema":2,"surface":"cli","session_id":"stale-1","hook_event_name":"UserPromptSubmit","observed_at_utc":"1970-01-01T00:00:00Z"}"#;
        let mut snapshot =
            parse_event_log(Path::new("stale-1.jsonl"), events, SystemTime::now()).unwrap();
        snapshot.apply_evidence_freshness(
            SystemTime::UNIX_EPOCH + Duration::from_secs(301),
            Duration::from_secs(300),
        );

        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Stale);
        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }
}
