use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::model::{
    AgentFamily, AttentionState, SessionSnapshot, Surface, parse_rfc3339_utc,
    presentation_session_name,
};

#[derive(Clone, Copy, PartialEq, Eq)]
struct FileStamp {
    len: u64,
    modified: SystemTime,
}

#[derive(Default)]
pub struct WatchDiscovery {
    observed_files: BTreeMap<PathBuf, FileStamp>,
}

pub fn discover(
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    discover_with_previous(root, now, stale_after, include_stale, None).0
}

pub fn discover_watch(
    state: &mut WatchDiscovery,
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let (snapshots, observed_files) = discover_with_previous(
        root,
        now,
        stale_after,
        include_stale,
        Some(&state.observed_files),
    );
    state.observed_files = observed_files;
    snapshots
}

fn discover_with_previous(
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
    previous_files: Option<&BTreeMap<PathBuf, FileStamp>>,
) -> (Vec<SessionSnapshot>, BTreeMap<PathBuf, FileStamp>) {
    let mut paths = Vec::new();
    collect_journals(root, &mut paths);

    let mut by_native_id: BTreeMap<String, SessionSnapshot> = BTreeMap::new();
    let mut observed_files = BTreeMap::new();
    for path in paths {
        let Some(stamp) = file_stamp(&path) else {
            continue;
        };
        let changed_since_previous = previous_files
            .and_then(|files| files.get(&path))
            .is_some_and(|previous| *previous != stamp);
        observed_files.insert(path.clone(), stamp);

        // Codex Desktop can keep a rollout handle open while appending. On
        // Windows, its length advances immediately but LastWriteTime may stay
        // at the first write until the handle closes. A watch must therefore
        // re-read a changed file even when its mtime has aged past the normal
        // discovery window. This only affects discovery; lifecycle freshness
        // still comes from the timestamp on the recognized journal event.
        let Some(snapshot) = parse_file(
            &path,
            now,
            stale_after,
            include_stale || changed_since_previous,
        ) else {
            continue;
        };
        let key = snapshot.native_session_id.clone();
        match by_native_id.get(&key) {
            Some(existing)
                if existing.last_source_activity_at >= snapshot.last_source_activity_at => {}
            _ => {
                by_native_id.insert(key, snapshot);
            }
        }
    }
    let titles = load_session_index(root);
    let mut snapshots = by_native_id.into_values().collect::<Vec<_>>();
    for snapshot in &mut snapshots {
        if snapshot.session_display_name.is_none() {
            snapshot.session_display_name = titles.get(&snapshot.native_session_id).cloned();
        }
    }
    snapshots.sort_by_key(|snapshot| std::cmp::Reverse(snapshot.last_source_activity_at));
    (snapshots, observed_files)
}

fn file_stamp(path: &Path) -> Option<FileStamp> {
    let metadata = fs::metadata(path).ok()?;
    Some(FileStamp {
        len: metadata.len(),
        modified: metadata.modified().ok()?,
    })
}

fn load_session_index(sessions_root: &Path) -> BTreeMap<String, String> {
    let Some(codex_root) = sessions_root.parent() else {
        return BTreeMap::new();
    };
    let Ok(text) = fs::read_to_string(codex_root.join("session_index.jsonl")) else {
        return BTreeMap::new();
    };
    parse_session_index(&text)
}

fn parse_session_index(text: &str) -> BTreeMap<String, String> {
    let mut indexed = BTreeMap::<String, (Option<SystemTime>, String)>::new();
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(native_id) = value.get("id").and_then(Value::as_str) else {
            continue;
        };
        let Some(title) = value
            .get("thread_name")
            .and_then(Value::as_str)
            .and_then(presentation_session_name)
        else {
            continue;
        };
        let updated_at = value
            .get("updated_at")
            .and_then(Value::as_str)
            .and_then(parse_rfc3339_utc);
        match indexed.get(native_id) {
            Some((existing_updated_at, _)) if *existing_updated_at > updated_at => {}
            _ => {
                indexed.insert(native_id.to_string(), (updated_at, title));
            }
        }
    }
    indexed
        .into_iter()
        .map(|(native_id, (_, title))| (native_id, title))
        .collect()
}

fn collect_journals(root: &Path, paths: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.file_name().and_then(|name| name.to_str()) != Some("subagents") {
                collect_journals(&path, paths);
            }
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
    let mut originator = None;
    let mut journal_source = None;
    let mut attention_state = AttentionState::Unknown;
    let mut attention_evidence = "no recognized lifecycle event".to_string();
    let mut last_attention_evidence_at = None;

    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        match value.get("type").and_then(Value::as_str) {
            Some("session_meta") => {
                let payload = value.get("payload").unwrap_or(&value);
                if is_subagent_source(payload.get("source")) {
                    return None;
                }
                journal_source = payload.get("source").cloned().or(journal_source);
                native_id = payload
                    .get("id")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
                    .or(native_id);
                cwd = payload
                    .get("cwd")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
                    .or(cwd);
                originator = payload
                    .get("originator")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
                    .or(originator);
            }
            Some("event_msg") => {
                let payload = value.get("payload").unwrap_or(&Value::Null);
                if let Some((next_attention, evidence)) = attention_from_event(payload) {
                    attention_state = next_attention;
                    attention_evidence = evidence.to_string();
                    last_attention_evidence_at = journal_timestamp(&value);
                }
            }
            _ => {}
        }
    }

    let inferred_from_filename = native_id.is_none();
    let native_session_id = native_id.or_else(|| {
        path.file_stem()
            .and_then(|name| name.to_str())
            .map(ToOwned::to_owned)
    })?;
    let source_label = journal_source.as_ref().and_then(source_label);
    let surface = surface_from_metadata(originator.as_deref(), source_label.as_deref());
    let mut source_parts = Vec::new();
    if let Some(source_label) = source_label {
        source_parts.push(format!("source: {source_label}"));
    }
    if let Some(originator) = originator {
        source_parts.push(format!("originator: {originator}"));
    }
    if inferred_from_filename {
        source_parts.push("id inferred from filename".to_string());
    }
    let source = if source_parts.is_empty() {
        "journal".to_string()
    } else {
        format!("journal ({})", source_parts.join("; "))
    };

    let mut snapshot = SessionSnapshot::new(
        AgentFamily::Codex,
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
    Some(snapshot)
}

fn journal_timestamp(value: &Value) -> Option<SystemTime> {
    value
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339_utc)
}

fn attention_from_event(payload: &Value) -> Option<(AttentionState, &'static str)> {
    let event_type = payload.get("type").and_then(Value::as_str)?;
    match event_type {
        "task_started" => Some((AttentionState::Working, "event_msg.task_started")),
        "task_complete" => Some((AttentionState::ResultReady, "event_msg.task_complete")),
        "turn_aborted" => Some((AttentionState::Interrupted, "event_msg.turn_aborted")),
        "agent_reasoning" => Some((AttentionState::Working, "event_msg.agent_reasoning")),
        other if other.contains("approval") || other.contains("permission") => {
            Some((AttentionState::NeedsMe, "event_msg approval/permission"))
        }
        _ => None,
    }
}

fn is_subagent_source(source: Option<&Value>) -> bool {
    match source {
        Some(Value::String(value)) => value == "subagent",
        Some(Value::Object(values)) => values.contains_key("subagent"),
        _ => false,
    }
}

fn source_label(source: &Value) -> Option<String> {
    match source {
        Value::String(value) => Some(value.clone()),
        Value::Object(values) if values.contains_key("subagent") => Some("subagent".to_string()),
        Value::Object(_) => Some("structured".to_string()),
        _ => None,
    }
}

fn surface_from_metadata(originator: Option<&str>, source: Option<&str>) -> Surface {
    if source.is_some_and(|source| source.eq_ignore_ascii_case("exec")) {
        return Surface::Cli;
    }
    let Some(originator) = originator else {
        return Surface::Unknown;
    };
    let originator = originator.to_ascii_lowercase();
    if originator.starts_with("codex desktop") || originator.starts_with("codex_work_desktop") {
        Surface::Desktop
    } else if ["codex_cli_rs", "codex-tui", "codex_exec"]
        .iter()
        .any(|prefix| originator.starts_with(prefix))
    {
        Surface::Cli
    } else {
        Surface::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::EvidenceFreshness;
    use std::fs::{FileTimes, OpenOptions};
    use std::io::Write;
    use std::time::UNIX_EPOCH;

    fn timestamp(raw: &str) -> SystemTime {
        parse_rfc3339_utc(raw).unwrap()
    }

    #[test]
    fn reads_codex_desktop_identity_and_completed_attention() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"session_meta","payload":{"id":"desktop-1","cwd":"D:\\ProjectA","originator":"Codex Desktop","source":"user"}}
{"timestamp":"2026-08-26T10:00:01Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-08-26T10:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}
"#;

        let snapshot = parse_journal(
            Path::new("rollout.jsonl"),
            journal,
            timestamp("2026-08-26T10:00:03Z"),
        )
        .unwrap();

        assert_eq!(snapshot.native_session_id, "desktop-1");
        assert_eq!(snapshot.cwd.as_deref(), Some("D:\\ProjectA"));
        assert_eq!(snapshot.surface, Surface::Desktop);
        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.session_display_name, None);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(timestamp("2026-08-26T10:00:02Z"))
        );
    }

    #[test]
    fn unrelated_journal_append_does_not_refresh_old_lifecycle_attention() {
        let journal = r#"
{"timestamp":"2026-08-26T10:00:00Z","type":"session_meta","payload":{"id":"desktop-1","originator":"Codex Desktop"}}
{"timestamp":"2026-08-26T10:00:01Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-08-26T11:00:00Z","type":"response_item","payload":{"type":"message"}}
"#;
        let source_activity_at = timestamp("2026-08-26T11:00:00Z");
        let mut snapshot =
            parse_journal(Path::new("rollout.jsonl"), journal, source_activity_at).unwrap();
        snapshot.apply_evidence_freshness(source_activity_at, Duration::from_secs(300));

        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(timestamp("2026-08-26T10:00:01Z"))
        );
        assert_eq!(snapshot.last_source_activity_at, source_activity_at);
        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Stale);
    }

    #[test]
    fn keeps_same_cwd_sessions_separate_by_native_id() {
        let a = r#"{"timestamp":"2026-08-26T10:00:00Z","type":"session_meta","payload":{"id":"a","cwd":"D:\\ProjectA","originator":"codex_cli_rs"}}"#;
        let b = r#"{"timestamp":"2026-08-26T10:00:00Z","type":"session_meta","payload":{"id":"b","cwd":"D:\\ProjectA","originator":"codex_cli_rs"}}"#;

        let first = parse_journal(Path::new("a.jsonl"), a, SystemTime::now()).unwrap();
        let second = parse_journal(Path::new("b.jsonl"), b, SystemTime::now()).unwrap();

        assert_eq!(first.cwd, second.cwd);
        assert_ne!(first.native_session_id, second.native_session_id);
    }

    #[test]
    fn codex_session_index_preserves_unicode_title_by_exact_native_id() {
        let index = r#"{"id":"a","thread_name":"完成 CP013 验收并激活 CP014","updated_at":"2026-08-27T12:26:01Z"}
{"id":"b","thread_name":"Review runtime binding","updated_at":"2026-08-27T12:27:01Z"}"#;

        let titles = parse_session_index(index);

        assert_eq!(
            titles.get("a").map(String::as_str),
            Some("完成 CP013 验收并激活 CP014")
        );
        assert_eq!(
            titles.get("b").map(String::as_str),
            Some("Review runtime binding")
        );
    }

    #[test]
    fn codex_session_index_uses_latest_exact_title_and_rejects_path_fallbacks() {
        let index = r#"{"id":"same","thread_name":"旧名称","updated_at":"2026-08-27T10:00:00Z"}
{"id":"other","thread_name":"D:\\ProjectA","updated_at":"2026-08-27T12:00:00Z"}
{"id":"same","thread_name":"最新名称","updated_at":"2026-08-27T11:00:00Z"}
{"id":"same","thread_name":"迟到的旧记录","updated_at":"2026-08-27T09:00:00Z"}"#;

        let titles = parse_session_index(index);

        assert_eq!(titles.get("same").map(String::as_str), Some("最新名称"));
        assert!(!titles.contains_key("other"));
    }

    #[test]
    fn omits_subagents() {
        let journal = r#"{"type":"session_meta","payload":{"id":"child","source":"subagent"}}"#;
        assert!(parse_journal(Path::new("child.jsonl"), journal, SystemTime::now()).is_none());
    }

    #[test]
    fn source_exec_wins_over_a_misleading_desktop_originator() {
        assert_eq!(
            surface_from_metadata(Some("Codex Desktop"), Some("exec")),
            Surface::Cli
        );
    }

    #[test]
    fn synthetic_freshness_regression_without_turning_working_into_result_ready() {
        const TARGET: &str = "11111111-1111-4111-8111-111111111111";
        let fixture = include_str!("../tests/fixtures/codex-working-freshness-synthetic.jsonl");
        let mut phases = Vec::new();

        for line in fixture.lines() {
            let value: Value = serde_json::from_str(line).unwrap();
            if value.get("native_session_id").and_then(Value::as_str) != Some(TARGET) {
                continue;
            }
            let evidence_at = value
                .get("last_evidence_unix_ms")
                .and_then(Value::as_u64)
                .map(|millis| UNIX_EPOCH + Duration::from_millis(millis))
                .unwrap();
            let observed_at = value
                .get("recorded_at_unix_ms")
                .and_then(Value::as_u64)
                .map(|millis| UNIX_EPOCH + Duration::from_millis(millis))
                .unwrap();
            let mut snapshot = SessionSnapshot::new(
                AgentFamily::Codex,
                Surface::Desktop,
                TARGET.to_string(),
                Some("D:\\agent-observer-crash-test".to_string()),
                "fixture journal".to_string(),
                observed_at,
            );
            snapshot.set_attention(
                AttentionState::Working,
                "event_msg.task_started",
                Some(evidence_at),
            );
            snapshot.apply_evidence_freshness(observed_at, Duration::from_secs(300));
            phases.push((snapshot.attention_state, snapshot.evidence_freshness));
        }

        assert_eq!(phases.len(), 3, "must process exactly three synthetic records");
        assert_eq!(
            phases,
            vec![
                (AttentionState::Working, EvidenceFreshness::Fresh),
                (AttentionState::Working, EvidenceFreshness::Aging),
                (AttentionState::Working, EvidenceFreshness::Stale),
            ],
            "phases must progress strictly through Fresh -> Aging -> Stale"
        );
        assert!(phases.contains(&(AttentionState::Working, EvidenceFreshness::Fresh)));
        assert!(phases.contains(&(AttentionState::Working, EvidenceFreshness::Aging)));
        assert!(phases.contains(&(AttentionState::Working, EvidenceFreshness::Stale)));
        assert!(
            phases
                .iter()
                .all(|(attention, _)| *attention == AttentionState::Working)
        );
    }

    #[test]
    fn watch_reparses_a_growing_journal_when_windows_mtime_stays_old() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "agent-observer-codex-growing-journal-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
        let journal = root.join("rollout-stale-mtime.jsonl");
        fs::write(
            &journal,
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"stale-mtime\",\"cwd\":\"D:\\\\ProjectA\",\"originator\":\"Codex Desktop\",\"source\":\"user\"}}\n",
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
            ),
        )
        .unwrap();

        let started_at = SystemTime::now();
        OpenOptions::new()
            .write(true)
            .open(&journal)
            .unwrap()
            .set_times(FileTimes::new().set_modified(started_at))
            .unwrap();
        let stale_after = Duration::from_secs(300);
        let mut watch = WatchDiscovery::default();
        let initial = discover_watch(
            &mut watch,
            &root,
            started_at + Duration::from_secs(1),
            stale_after,
            false,
        );
        assert_eq!(initial.len(), 1);
        assert_eq!(initial[0].attention_state, AttentionState::Working);

        let mut file = OpenOptions::new().append(true).open(&journal).unwrap();
        writeln!(
            file,
            "{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"task_complete\"}}}}"
        )
        .unwrap();
        drop(file);
        OpenOptions::new()
            .write(true)
            .open(&journal)
            .unwrap()
            .set_times(FileTimes::new().set_modified(started_at))
            .unwrap();

        let completed = discover_watch(
            &mut watch,
            &root,
            started_at + Duration::from_secs(600),
            stale_after,
            false,
        );
        assert_eq!(completed.len(), 1);
        assert_eq!(completed[0].attention_state, AttentionState::ResultReady);
        assert_eq!(completed[0].attention_evidence, "event_msg.task_complete");

        let unchanged = discover_watch(
            &mut watch,
            &root,
            started_at + Duration::from_secs(601),
            stale_after,
            false,
        );
        assert!(unchanged.is_empty());
        fs::remove_dir_all(root).unwrap();
    }
}
