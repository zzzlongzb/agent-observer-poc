use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::Value;

use crate::model::{
    AgentFamily, AttentionState, HostLiveness, SessionLiveness, SessionSnapshot, Surface,
    parse_rfc3339_utc, presentation_session_name,
};
use crate::process::query_process;

/// Values at or above 10^12 are treated as Unix milliseconds. Smaller
/// non-negative integers are Unix seconds. Grok `updates.jsonl` writes
/// seconds on `timestamp`. The parser never uses journal mtime as attention
/// evidence.
const UNIX_MILLIS_THRESHOLD: u64 = 1_000_000_000_000;

pub fn discover(
    session_root: &Path,
    active_sessions_path: &Path,
    hook_root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let active = load_active_sessions(active_sessions_path);
    let mut snapshots = discover_sessions(session_root, &active, now, stale_after, include_stale);
    snapshots.extend(discover_hooks(hook_root, now, stale_after, include_stale));
    snapshots
}

fn discover_sessions(
    root: &Path,
    active_sessions: &BTreeMap<String, u32>,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let mut summaries = Vec::new();
    collect_named_files(root, "summary.json", &mut summaries);
    let mut snapshots = Vec::new();
    for summary_path in summaries {
        let updates_path = summary_path.parent().unwrap_or(root).join("updates.jsonl");
        let Some(latest_modified) = latest_modified(&summary_path, &updates_path) else {
            continue;
        };
        if !include_stale && now.duration_since(latest_modified).unwrap_or_default() > stale_after {
            continue;
        }
        let Some(mut snapshot) = parse_session(&summary_path, &updates_path, latest_modified)
        else {
            continue;
        };
        snapshot.apply_evidence_freshness(now, stale_after);
        if let Some(process_id) = active_sessions.get(&snapshot.native_session_id) {
            match query_process(*process_id) {
                Ok(Some(_)) => snapshot.set_host_liveness(
                    HostLiveness::Alive,
                    "Grok active_sessions registry points to a live PID",
                    now,
                ),
                Ok(None) => snapshot.set_host_liveness(
                    HostLiveness::Unknown,
                    "Grok active_sessions PID disappeared; no creation-time binding, so DEAD is not asserted",
                    now,
                ),
                Err(message) => snapshot.set_host_liveness(
                    HostLiveness::Unreachable,
                    format!("Grok active_sessions PID could not be checked: {message}"),
                    now,
                ),
            }
        }
        snapshots.push(snapshot);
    }
    snapshots
}

fn parse_session(
    summary_path: &Path,
    updates_path: &Path,
    fallback_source_activity_at: SystemTime,
) -> Option<SessionSnapshot> {
    let summary = serde_json::from_str::<Value>(&fs::read_to_string(summary_path).ok()?).ok()?;
    let info = summary.get("info")?;
    let native_id = info.get("id")?.as_str()?.to_string();
    let cwd = info
        .get("cwd")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let display_name = summary
        .get("generated_title")
        .and_then(Value::as_str)
        .and_then(presentation_session_name)
        .or_else(|| {
            summary
                .get("session_summary")
                .and_then(Value::as_str)
                .and_then(presentation_session_name)
        });
    let mut source_activity_at = summary_time(&summary).unwrap_or(fallback_source_activity_at);
    let mut attention: Option<(AttentionState, String, Option<SystemTime>)> = None;
    let mut turns = GrokTurnState::default();
    if let Ok(text) = fs::read_to_string(updates_path) {
        for value in json_lines(&text) {
            let event_at = value.get("timestamp").and_then(parse_timestamp_value);
            if let Some(event_at) = event_at {
                source_activity_at = source_activity_at.max(event_at);
            }
            let update = value.get("params").and_then(|params| params.get("update"));
            let removal = turns.apply(update);
            if let Some((state, evidence)) = turns.attention(update, removal) {
                // Invalid or missing timestamps must not refresh attention
                // evidence. The attention state may still change.
                let evidence_at = event_at.or_else(|| attention.and_then(|item| item.2));
                attention = Some((state, evidence, evidence_at));
            }
        }
    }

    let mut snapshot = SessionSnapshot::new(
        AgentFamily::Grok,
        Surface::Cli,
        native_id,
        cwd,
        "grok-session (passive)".to_string(),
        source_activity_at,
    );
    snapshot.session_display_name = display_name;
    if let Some((state, evidence, at)) = attention {
        snapshot.set_attention(state, evidence, at);
    }
    snapshot.set_session_liveness(
        SessionLiveness::Unknown,
        "passive Grok session data has no exact PID creation-time binding",
        None,
    );
    Some(snapshot)
}

/// Evidence string used whenever the conservative settle predicate holds.
const SETTLE_EVIDENCE: &str = "Grok turn_completed(end_turn) with no remaining background work, subagent, schedule, retry, or compaction";

/// Whether a lifecycle event removed an identifier this journal was already
/// tracking. An identifier we never saw created means the journal evidence is
/// incomplete, which must be treated as "still active", never as settled.
#[derive(Clone, Copy, PartialEq, Eq)]
enum TrackedRemoval {
    NotApplicable,
    Tracked,
    Untracked,
}

/// The passive-journal activity classes whose lifecycle evidence can become
/// incomplete. A missing or never-seen identifier is evidence the journal is
/// missing part of the lifecycle, not evidence the activity ended.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum GrokLifecycleKind {
    BackgroundTask,
    Subagent,
    ScheduledTask,
}

impl GrokLifecycleKind {
    fn label(self) -> &'static str {
        match self {
            GrokLifecycleKind::BackgroundTask => "background task",
            GrokLifecycleKind::Subagent => "subagent",
            GrokLifecycleKind::ScheduledTask => "scheduled task",
        }
    }
}

/// Turn and activity state for one passive Grok journal.
///
/// Only identifiers are retained: background task ids, subagent ids, and
/// scheduled task ids. `description`, `output`, `model`, `prompt`, assistant
/// text, and tool bodies are never read and never stored.
#[derive(Default)]
struct GrokTurnState {
    turn_seq: u64,
    ended_turn_seq: Option<u64>,
    pending_from_ended_turn: BTreeSet<String>,
    active_background_tasks: BTreeMap<String, u64>,
    active_subagents: BTreeSet<String>,
    active_scheduled_tasks: BTreeSet<String>,
    /// Sticky completion blockers for lifecycle classes whose evidence is
    /// incomplete. Never cleared during a replay: a background task, subagent,
    /// or schedule can outlive the turn that observed the gap, so no later
    /// event may prove the gap was harmless.
    incomplete_lifecycles: BTreeSet<GrokLifecycleKind>,
    retry_active: bool,
    compact_active: bool,
}

impl GrokTurnState {
    /// Applies one `sessionUpdate` and reports whether a lifecycle-removal
    /// event named an identifier this journal was already tracking.
    fn apply(&mut self, update: Option<&Value>) -> TrackedRemoval {
        let Some(update) = update else {
            return TrackedRemoval::NotApplicable;
        };
        let Some(update_type) = update.get("sessionUpdate").and_then(Value::as_str) else {
            return TrackedRemoval::NotApplicable;
        };
        match update_type {
            "user_message_chunk" => {
                self.turn_seq = self.turn_seq.saturating_add(1);
                self.ended_turn_seq = None;
                self.pending_from_ended_turn.clear();
                self.retry_active = false;
            }
            "task_backgrounded" => match string_field(update, "task_id") {
                Some(task_id) => {
                    self.active_background_tasks.insert(task_id, self.turn_seq);
                }
                // A background task we cannot name can never be proven
                // finished, so its lifecycle is permanently incomplete.
                None => self.mark_incomplete(GrokLifecycleKind::BackgroundTask),
            },
            "task_completed" => {
                let task_id = update
                    .get("task_snapshot")
                    .and_then(|snapshot| string_field(snapshot, "task_id"));
                return match task_id {
                    Some(task_id) => {
                        let tracked = self.active_background_tasks.remove(&task_id).is_some();
                        let pending = self.pending_from_ended_turn.remove(&task_id);
                        if tracked || pending {
                            TrackedRemoval::Tracked
                        } else {
                            self.mark_incomplete(GrokLifecycleKind::BackgroundTask);
                            TrackedRemoval::Untracked
                        }
                    }
                    None => {
                        self.mark_incomplete(GrokLifecycleKind::BackgroundTask);
                        TrackedRemoval::NotApplicable
                    }
                };
            }
            "subagent_spawned" => match string_field(update, "subagent_id") {
                Some(subagent_id) => {
                    self.active_subagents.insert(subagent_id);
                }
                None => self.mark_incomplete(GrokLifecycleKind::Subagent),
            },
            "subagent_finished" => {
                let removal = remove_tracked(
                    &mut self.active_subagents,
                    string_field(update, "subagent_id"),
                );
                if removal != TrackedRemoval::Tracked {
                    self.mark_incomplete(GrokLifecycleKind::Subagent);
                }
                return removal;
            }
            "scheduled_task_created" => match string_field(update, "task_id") {
                Some(task_id) => {
                    self.active_scheduled_tasks.insert(task_id);
                }
                None => self.mark_incomplete(GrokLifecycleKind::ScheduledTask),
            },
            "scheduled_task_deleted" => {
                let removal = remove_tracked(
                    &mut self.active_scheduled_tasks,
                    string_field(update, "task_id"),
                );
                if removal != TrackedRemoval::Tracked {
                    self.mark_incomplete(GrokLifecycleKind::ScheduledTask);
                }
                return removal;
            }
            "auto_compact_started" => self.compact_active = true,
            "auto_compact_completed" | "auto_compact_failed" | "auto_compact_cancelled" => {
                self.compact_active = false;
            }
            "retry_state" => {
                let retry_type = update.get("type").and_then(Value::as_str);
                let exhausted = update.get("exhausted").and_then(Value::as_bool) == Some(true);
                self.retry_active = retry_type != Some("error") && !exhausted;
            }
            "turn_completed" => match update.get("stop_reason").and_then(Value::as_str) {
                Some("end_turn") => {
                    self.ended_turn_seq = Some(self.turn_seq);
                    let pending: Vec<String> = self
                        .active_background_tasks
                        .iter()
                        .filter(|(_, seq)| **seq == self.turn_seq)
                        .map(|(task_id, _)| task_id.clone())
                        .collect();
                    self.pending_from_ended_turn.clear();
                    self.pending_from_ended_turn.extend(pending);
                    // Official retry happens inside a turn instead of ending
                    // it, so turn_completed(end_turn) means retry is over.
                    self.retry_active = false;
                }
                Some("cancelled" | "error") => {
                    self.ended_turn_seq = None;
                    self.pending_from_ended_turn.clear();
                    self.retry_active = false;
                }
                _ => {}
            },
            _ => {}
        }
        TrackedRemoval::NotApplicable
    }

    /// Records that one lifecycle class can no longer be proven complete.
    ///
    /// The mark is intentionally sticky for the whole replay. Background
    /// tasks, subagents, and schedules may all outlive a turn, so no later
    /// `user_message_chunk`, `turn_completed`, known-id completion, host
    /// liveness change, or freshness change may clear it.
    fn mark_incomplete(&mut self, kind: GrokLifecycleKind) {
        self.incomplete_lifecycles.insert(kind);
    }

    /// The single conservative completion gate for the passive journal.
    ///
    /// Every condition must be *known* to hold. Anything unknown or still
    /// active keeps the session at `WORKING`. A lifecycle class with
    /// incomplete evidence blocks settlement forever, because an empty active
    /// set plus incomplete evidence means "unknown", never "finished".
    fn can_settle(&self) -> bool {
        self.ended_turn_seq == Some(self.turn_seq)
            && self.active_background_tasks.is_empty()
            && self.pending_from_ended_turn.is_empty()
            && self.active_subagents.is_empty()
            && self.active_scheduled_tasks.is_empty()
            && self.incomplete_lifecycles.is_empty()
            && !self.retry_active
            && !self.compact_active
    }

    fn blocked_reason(&self) -> String {
        if !self.incomplete_lifecycles.is_empty() {
            let labels: Vec<&str> = self
                .incomplete_lifecycles
                .iter()
                .map(|kind| kind.label())
                .collect();
            return format!(
                "Grok journal lifecycle evidence is incomplete for {}; completion stays blocked",
                labels.join(" + ")
            );
        }
        let reason = if !self.active_subagents.is_empty() {
            "Grok turn completed while a subagent was still active"
        } else if !self.active_scheduled_tasks.is_empty() {
            "Grok turn completed while a scheduled task was still active"
        } else {
            "Grok turn completed while background work remained active"
        };
        reason.to_string()
    }

    fn attention(
        &self,
        update: Option<&Value>,
        removal: TrackedRemoval,
    ) -> Option<(AttentionState, String)> {
        let update_type = update
            .and_then(|update| update.get("sessionUpdate"))
            .and_then(Value::as_str)?;
        match update_type {
            "user_message_chunk" => Some((
                AttentionState::Working,
                "Grok user_message_chunk started a new turn".to_string(),
            )),
            "agent_message_chunk"
            | "agent_thought_chunk"
            | "tool_call"
            | "tool_call_update"
            | "task_backgrounded"
            | "subagent_spawned"
            | "scheduled_task_created" => Some((
                AttentionState::Working,
                "Grok session update indicates active work".to_string(),
            )),
            "auto_compact_started" => Some((
                AttentionState::Working,
                "Grok auto-compact is active".to_string(),
            )),
            "auto_compact_completed" | "auto_compact_failed" | "auto_compact_cancelled" => {
                if self.can_settle() {
                    Some((AttentionState::ResultReady, SETTLE_EVIDENCE.to_string()))
                } else {
                    Some((AttentionState::Working, self.blocked_reason()))
                }
            }
            "retry_state" => match update
                .and_then(|update| update.get("type"))
                .and_then(Value::as_str)
            {
                Some("error") => Some((
                    AttentionState::Interrupted,
                    "Grok retry state reported an error".to_string(),
                )),
                _ => Some((AttentionState::Working, "Grok retry is active".to_string())),
            },
            "turn_completed" => match update
                .and_then(|update| update.get("stop_reason"))
                .and_then(Value::as_str)
            {
                Some("end_turn") => {
                    if self.can_settle() {
                        Some((AttentionState::ResultReady, SETTLE_EVIDENCE.to_string()))
                    } else {
                        // An incomplete lifecycle blocker is permanent, so a
                        // compaction or turn completion can never green it.
                        Some((AttentionState::Working, self.blocked_reason()))
                    }
                }
                Some("cancelled" | "error") => Some((
                    AttentionState::Interrupted,
                    "Grok turn_completed without normal completion".to_string(),
                )),
                _ => None,
            },
            // A background task completion can trigger an auto-wake synthetic
            // prompt, so it never settles the session by itself. Only the next
            // real turn completion may re-evaluate RESULT_READY.
            "task_completed" => Some((
                AttentionState::Working,
                task_completed_evidence(removal).to_string(),
            )),
            "subagent_finished" => Some((
                AttentionState::Working,
                subagent_finished_evidence(update, removal).to_string(),
            )),
            "scheduled_task_deleted" => Some((
                AttentionState::Working,
                scheduled_task_deleted_evidence(removal).to_string(),
            )),
            _ => None,
        }
    }
}

fn remove_tracked(set: &mut BTreeSet<String>, id: Option<String>) -> TrackedRemoval {
    match id {
        Some(id) if set.remove(&id) => TrackedRemoval::Tracked,
        Some(_) => TrackedRemoval::Untracked,
        None => TrackedRemoval::NotApplicable,
    }
}

fn task_completed_evidence(removal: TrackedRemoval) -> &'static str {
    match removal {
        TrackedRemoval::Tracked => {
            "Grok background task completed; an auto-wake turn may still follow"
        }
        TrackedRemoval::Untracked => {
            "Grok task_completed named a background task this journal never saw backgrounded; lifecycle evidence is incomplete"
        }
        TrackedRemoval::NotApplicable => {
            "Grok task_completed carried no usable task_snapshot.task_id; lifecycle evidence is incomplete"
        }
    }
}

fn subagent_finished_evidence(update: Option<&Value>, removal: TrackedRemoval) -> &'static str {
    let will_wake = update
        .and_then(|update| update.get("will_wake"))
        .and_then(Value::as_bool)
        == Some(true);
    match removal {
        TrackedRemoval::Tracked if will_wake => {
            "Grok subagent finished and asked to wake the session; only the next turn may settle it"
        }
        TrackedRemoval::Tracked => {
            "Grok subagent finished; only a later turn completion may settle the session"
        }
        TrackedRemoval::Untracked => {
            "Grok subagent_finished named a subagent this journal never saw spawn; lifecycle evidence is incomplete"
        }
        TrackedRemoval::NotApplicable => {
            "Grok subagent_finished carried no subagent id; lifecycle evidence is incomplete"
        }
    }
}

fn scheduled_task_deleted_evidence(removal: TrackedRemoval) -> &'static str {
    match removal {
        TrackedRemoval::Tracked => {
            "Grok scheduled task removed; only a later turn completion may settle the session"
        }
        TrackedRemoval::Untracked => {
            "Grok scheduled_task_deleted named a task this journal never saw created; lifecycle evidence is incomplete"
        }
        TrackedRemoval::NotApplicable => {
            "Grok scheduled_task_deleted carried no task id; lifecycle evidence is incomplete"
        }
    }
}

fn grok_update_attention(value: &Value) -> Option<(AttentionState, String)> {
    let update = value.get("params")?.get("update");
    let turns = GrokTurnState {
        turn_seq: 0,
        ended_turn_seq: Some(0),
        ..GrokTurnState::default()
    };
    turns.attention(update, TrackedRemoval::NotApplicable)
}

fn discover_hooks(
    root: &Path,
    now: SystemTime,
    stale_after: Duration,
    include_stale: bool,
) -> Vec<SessionSnapshot> {
    let mut files = Vec::new();
    collect_extensions(root, &["json", "jsonl"], &mut files);
    let mut events_by_id: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    let mut fallback_by_id = BTreeMap::new();
    for path in files {
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
        for value in json_lines(&text).filter(is_grok_hook_record) {
            let Some(native_id) = value
                .get("session_id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
            else {
                continue;
            };
            events_by_id
                .entry(native_id.clone())
                .or_default()
                .push(value);
            fallback_by_id.insert(native_id, modified);
        }
    }
    events_by_id
        .into_iter()
        .filter_map(|(id, mut events)| {
            events.sort_by_key(hook_timestamp);
            let fallback = fallback_by_id.get(&id).copied().unwrap_or(now);
            let mut snapshot = parse_hook_events(&events, fallback)?;
            snapshot.apply_evidence_freshness(now, stale_after);
            Some(snapshot)
        })
        .collect()
}

fn parse_hook_events(
    events: &[Value],
    fallback_source_activity_at: SystemTime,
) -> Option<SessionSnapshot> {
    let mut native_id = None;
    let mut cwd = None;
    let mut attention = None;
    let mut detached_at = None;
    let mut last_source_activity_at = None;
    let mut newest_prompt_id = None;

    for value in events {
        let event_at = hook_timestamp(value);
        update_latest(&mut last_source_activity_at, event_at);
        native_id = string_field(value, "session_id").or(native_id);
        cwd = string_field(value, "cwd").or(cwd);
        let prompt_id = value.get("prompt_id").and_then(Value::as_str);
        // A single malformed record must not hide every other event of the
        // session; skip it instead of aborting the whole parse.
        let Some(event) = value.get("event").and_then(Value::as_str) else {
            continue;
        };
        if event == "UserPromptSubmit" {
            if let Some(prompt_id) = prompt_id {
                newest_prompt_id = Some(prompt_id.to_string());
            }
            attention = Some((
                AttentionState::Working,
                "Grok hook observed UserPromptSubmit",
                event_at,
            ));
            continue;
        }
        if prompt_id.is_some()
            && newest_prompt_id.as_deref().is_some()
            && prompt_id != newest_prompt_id.as_deref()
        {
            continue;
        }
        match event {
            "PreToolUse" | "PostToolUse" | "PostToolUseFailure" => {
                attention = Some((
                    AttentionState::Working,
                    "Grok hook observed active tool work",
                    event_at,
                ));
            }
            "Notification"
                if value.get("notification_type").and_then(Value::as_str)
                    == Some("permission_prompt") =>
            {
                attention = Some((
                    AttentionState::NeedsMe,
                    "Grok hook observed a permission prompt",
                    event_at,
                ));
            }
            "PermissionDenied" | "StopFailure" | "StopCancelled" => {
                attention = Some((
                    AttentionState::Interrupted,
                    "Grok hook observed an interrupted turn",
                    event_at,
                ));
            }
            "Stop" if value.get("reason").and_then(Value::as_str) == Some("end_turn") => {
                attention = Some(stop_attention(value, event_at));
            }
            "SessionEnd" => detached_at = event_at,
            _ => {}
        }
    }

    let mut snapshot = SessionSnapshot::new(
        AgentFamily::Grok,
        Surface::Cli,
        native_id?,
        cwd,
        "hook (Grok Build)".to_string(),
        last_source_activity_at.unwrap_or(fallback_source_activity_at),
    );
    if let Some((state, evidence, at)) = attention {
        snapshot.set_attention(state, evidence, at);
    }
    if let Some(at) = detached_at {
        snapshot.set_session_liveness(
            SessionLiveness::Detached,
            "Grok hook observed SessionEnd",
            Some(at),
        );
    } else {
        snapshot.set_session_liveness(
            SessionLiveness::Unknown,
            "ordinary Grok TUI is not Observer-owned; LOST is not inferred",
            None,
        );
    }
    Some(snapshot)
}

fn stop_attention(
    value: &Value,
    at: Option<SystemTime>,
) -> (AttentionState, &'static str, Option<SystemTime>) {
    let background = value.get("background_tasks");
    let crons = value.get("session_crons");
    if collection_has_items(background) || collection_has_items(crons) {
        return (
            AttentionState::Working,
            "Grok Stop reported active background work",
            at,
        );
    }
    if matches!(background, Some(Value::Array(items)) if items.is_empty())
        && matches!(crons, Some(Value::Array(items)) if items.is_empty())
    {
        return (
            AttentionState::ResultReady,
            "Grok Stop reported no background work",
            at,
        );
    }
    (
        AttentionState::Working,
        "Grok Stop lacked complete background-work evidence",
        at,
    )
}

fn load_active_sessions(path: &Path) -> BTreeMap<String, u32> {
    let Ok(text) = fs::read_to_string(path) else {
        return BTreeMap::new();
    };
    let Ok(Value::Array(entries)) = serde_json::from_str::<Value>(&text) else {
        return BTreeMap::new();
    };
    entries
        .into_iter()
        .filter_map(|entry| {
            Some((
                entry.get("session_id")?.as_str()?.to_string(),
                u32::try_from(entry.get("pid")?.as_u64()?).ok()?,
            ))
        })
        .collect()
}

fn summary_time(summary: &Value) -> Option<SystemTime> {
    ["last_active_at", "updated_at", "created_at"]
        .into_iter()
        .find_map(|field| summary.get(field).and_then(parse_timestamp_value))
}

fn parse_timestamp_value(value: &Value) -> Option<SystemTime> {
    match value {
        Value::String(raw) => parse_rfc3339_utc(raw),
        Value::Number(number) => parse_unix_timestamp_number(number),
        _ => None,
    }
}

fn parse_unix_timestamp_number(number: &serde_json::Number) -> Option<SystemTime> {
    if let Some(value) = number.as_i64() {
        if value < 0 {
            return None;
        }
        return system_time_from_unix_epoch_int(value as u64);
    }
    if let Some(value) = number.as_u64() {
        return system_time_from_unix_epoch_int(value);
    }
    None
}

fn system_time_from_unix_epoch_int(value: u64) -> Option<SystemTime> {
    let duration = if value >= UNIX_MILLIS_THRESHOLD {
        let seconds = value / 1_000;
        let millis = value % 1_000;
        Duration::from_secs(seconds).checked_add(Duration::from_millis(millis))?
    } else {
        Duration::from_secs(value)
    };
    SystemTime::UNIX_EPOCH.checked_add(duration)
}

fn latest_modified(first: &Path, second: &Path) -> Option<SystemTime> {
    let first = fs::metadata(first).ok()?.modified().ok()?;
    let second = fs::metadata(second)
        .ok()
        .and_then(|value| value.modified().ok())
        .unwrap_or(first);
    Some(first.max(second))
}

fn hook_timestamp(value: &Value) -> Option<SystemTime> {
    value
        .get("observed_at_utc")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339_utc)
}

fn is_grok_hook_record(value: &Value) -> bool {
    value.get("observer_schema").and_then(Value::as_u64) == Some(1)
        && value.get("source").and_then(Value::as_str) == Some("grok-hook")
}

fn collection_has_items(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Array(items)) if !items.is_empty())
}

fn string_field(value: &Value, name: &str) -> Option<String> {
    value
        .get(name)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn json_lines(text: &str) -> impl Iterator<Item = Value> + '_ {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
}

fn update_latest(target: &mut Option<SystemTime>, candidate: Option<SystemTime>) {
    if let Some(candidate) = candidate {
        *target = Some(target.map_or(candidate, |current| current.max(candidate)));
    }
}

fn collect_named_files(root: &Path, name: &str, paths: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_named_files(&path, name, paths);
        } else if path.file_name().and_then(|value| value.to_str()) == Some(name) {
            paths.push(path);
        }
    }
}

fn collect_extensions(root: &Path, extensions: &[&str], paths: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_extensions(&path, extensions, paths);
        } else if path
            .extension()
            .and_then(|value| value.to_str())
            .is_some_and(|value| extensions.contains(&value))
        {
            paths.push(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::EvidenceFreshness;

    const FIXTURE_TS: u64 = 1_788_250_000;

    fn value(raw: &str) -> Value {
        serde_json::from_str(raw).unwrap()
    }

    fn unix_secs(secs: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(secs)
    }

    fn write_session(root: &Path, id: &str, cwd: &str, updates: &str) {
        let dir = root.join(id);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("summary.json"),
            format!(
                r#"{{"info":{{"id":"{id}","cwd":{cwd:?}}},"generated_title":"fixture {id}","updated_at":"2026-09-01T08:00:00Z"}}"#
            ),
        )
        .unwrap();
        fs::write(dir.join("updates.jsonl"), updates).unwrap();
    }

    fn parse_updates(label: &str, updates: &str) -> SessionSnapshot {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-grok-resp-{}-{label}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        write_session(&root, "sess", r"D:\work", updates);
        let summary = root.join("sess").join("summary.json");
        let updates_path = root.join("sess").join("updates.jsonl");
        let snapshot = parse_session(&summary, &updates_path, SystemTime::UNIX_EPOCH).unwrap();
        let _ = fs::remove_dir_all(&root);
        snapshot
    }

    fn hud_would_admit(snapshot: &SessionSnapshot) -> bool {
        matches!(
            snapshot.evidence_freshness,
            EvidenceFreshness::Fresh | EvidenceFreshness::Aging
        ) && snapshot.attention_state != AttentionState::Unknown
            && snapshot.session_liveness != SessionLiveness::Lost
    }

    #[test]
    fn passive_grok_end_turn_with_empty_work_is_result_ready_and_cancel_is_interrupted() {
        let ready = value(
            r#"{"params":{"update":{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}}}"#,
        );
        let cancelled = value(
            r#"{"params":{"update":{"sessionUpdate":"turn_completed","stop_reason":"cancelled"}}}"#,
        );

        assert_eq!(
            grok_update_attention(&ready).unwrap().0,
            AttentionState::ResultReady
        );
        assert_eq!(
            grok_update_attention(&cancelled).unwrap().0,
            AttentionState::Interrupted
        );
    }

    #[test]
    fn grok_stop_with_background_work_never_becomes_result_ready() {
        let events = vec![
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","cwd":"D:\\work","prompt_id":"p1","observed_at_utc":"2026-08-31T10:00:00Z"}"#,
            ),
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"Stop","reason":"end_turn","session_id":"grok-1","cwd":"D:\\work","prompt_id":"p1","background_tasks":[{"id":"task-1","type":"shell","status":"running"}],"session_crons":[],"observed_at_utc":"2026-08-31T10:00:01Z"}"#,
            ),
        ];
        let snapshot = parse_hook_events(&events, SystemTime::UNIX_EPOCH).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn grok_stop_with_explicitly_empty_background_work_is_result_ready() {
        let events = vec![
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-08-31T10:00:00Z"}"#,
            ),
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"Stop","reason":"end_turn","session_id":"grok-1","prompt_id":"p1","background_tasks":[],"session_crons":[],"observed_at_utc":"2026-08-31T10:00:01Z"}"#,
            ),
        ];
        let snapshot = parse_hook_events(&events, SystemTime::UNIX_EPOCH).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
    }

    #[test]
    fn passive_turn_completion_with_background_task_stays_working() {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-grok-background-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let summary = root.join("summary.json");
        let updates = root.join("updates.jsonl");
        fs::write(
            &summary,
            r#"{"info":{"id":"grok-background","cwd":"D:\\work"},"generated_title":"后台验证","updated_at":"2026-08-31T10:00:02Z"}"#,
        )
        .unwrap();
        fs::write(
            &updates,
            concat!(
                "{\"timestamp\":\"2026-08-31T10:00:01Z\",\"params\":{\"update\":{\"sessionUpdate\":\"task_backgrounded\",\"task_id\":\"task-1\"}}}\n",
                "{\"timestamp\":\"2026-08-31T10:00:02Z\",\"params\":{\"update\":{\"sessionUpdate\":\"turn_completed\",\"stop_reason\":\"end_turn\"}}}\n"
            ),
        )
        .unwrap();

        let snapshot = parse_session(&summary, &updates, SystemTime::UNIX_EPOCH).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_ne!(snapshot.attention_state, AttentionState::ResultReady);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn stale_or_out_of_order_old_prompt_end_cannot_settle_new_work() {
        let events = vec![
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","prompt_id":"old","observed_at_utc":"2026-08-31T10:00:00Z"}"#,
            ),
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","prompt_id":"new","observed_at_utc":"2026-08-31T10:00:02Z"}"#,
            ),
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"StopCancelled","session_id":"grok-1","prompt_id":"old","observed_at_utc":"2026-08-31T10:00:03Z"}"#,
            ),
        ];
        let snapshot = parse_hook_events(&events, SystemTime::UNIX_EPOCH).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }

    #[test]
    fn ordinary_grok_hook_never_claims_lost() {
        let events = vec![value(
            r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-08-31T10:00:00Z"}"#,
        )];
        let snapshot = parse_hook_events(&events, SystemTime::UNIX_EPOCH).unwrap();
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn grok_stop_only_turns_green_for_two_explicit_empty_arrays() {
        let at = Some(SystemTime::UNIX_EPOCH);
        let ready = value(
            r#"{"event":"Stop","reason":"end_turn","background_tasks":[],"session_crons":[]}"#,
        );
        assert_eq!(stop_attention(&ready, at).0, AttentionState::ResultReady);

        // null, missing, object, string, and non-empty arrays are all
        // "background-work evidence unknown or active", never green.
        for raw in [
            r#"{"event":"Stop","reason":"end_turn","background_tasks":null,"session_crons":[]}"#,
            r#"{"event":"Stop","reason":"end_turn","background_tasks":[],"session_crons":null}"#,
            r#"{"event":"Stop","reason":"end_turn","background_tasks":{"unexpected":true},"session_crons":[]}"#,
            r#"{"event":"Stop","reason":"end_turn","background_tasks":"running","session_crons":[]}"#,
            r#"{"event":"Stop","reason":"end_turn","background_tasks":[{"id":"t1"}],"session_crons":[]}"#,
            r#"{"event":"Stop","reason":"end_turn"}"#,
        ] {
            let payload = value(raw);
            assert_eq!(
                stop_attention(&payload, at).0,
                AttentionState::Working,
                "unexpected completion state for {raw}"
            );
        }
    }

    #[test]
    fn malformed_grok_record_does_not_hide_the_whole_session() {
        let events = vec![
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-08-31T10:00:00Z"}"#,
            ),
            // Malformed: our schema and source, but no event name.
            value(
                r#"{"observer_schema":1,"source":"grok-hook","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-08-31T10:00:01Z"}"#,
            ),
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"Stop","reason":"end_turn","session_id":"grok-1","prompt_id":"p1","background_tasks":[],"session_crons":[],"observed_at_utc":"2026-08-31T10:00:02Z"}"#,
            ),
        ];
        let snapshot = parse_hook_events(&events, SystemTime::UNIX_EPOCH)
            .expect("a malformed record must not drop the session");

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
    }

    fn update_line(timestamp_json: &str, update: &str) -> String {
        format!(r#"{{"timestamp":{timestamp_json},"params":{{"update":{update}}}}}"#)
    }

    fn with_freshness(mut snapshot: SessionSnapshot, now: SystemTime) -> SessionSnapshot {
        snapshot.apply_evidence_freshness(now, Duration::from_secs(300));
        snapshot
    }

    fn discover_sessions_at(root: &Path, now: SystemTime) -> Vec<SessionSnapshot> {
        let hooks = root.join("hooks");
        let _ = fs::create_dir_all(&hooks);
        let active = root.join("active_sessions.json");
        if !active.exists() {
            fs::write(&active, "[]").unwrap();
        }
        discover(root, &active, &hooks, now, Duration::from_secs(300), true)
    }

    #[test]
    fn parse_timestamp_value_accepts_rfc3339_unix_seconds_and_millis() {
        assert_eq!(
            parse_timestamp_value(&value(r#""2026-09-01T08:06:40Z""#)),
            Some(unix_secs(FIXTURE_TS))
        );
        assert_eq!(
            parse_timestamp_value(&value("1788250000")),
            Some(unix_secs(FIXTURE_TS))
        );
        assert_eq!(
            parse_timestamp_value(&value("1788250000000")),
            Some(unix_secs(FIXTURE_TS))
        );
    }

    #[test]
    fn parse_timestamp_value_rejects_illegal_negative_fractional_and_overflow() {
        for raw in [
            "null",
            "true",
            "-1",
            "1.5",
            r#""not-a-timestamp""#,
            "{}",
            "[]",
            "18446744073709551615",
        ] {
            assert_eq!(
                parse_timestamp_value(&value(raw)),
                None,
                "timestamp {raw} must be rejected"
            );
        }
    }

    #[test]
    fn numeric_unix_seconds_produce_fresh_working_attention_evidence() {
        let snapshot = with_freshness(
            parse_updates(
                "numeric-secs",
                &update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            ),
            unix_secs(FIXTURE_TS + 1),
        );

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS))
        );
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Fresh);
        assert_ne!(
            snapshot.last_attention_evidence_at,
            Some(SystemTime::UNIX_EPOCH)
        );
        assert!(hud_would_admit(&snapshot));
    }

    #[test]
    fn rfc3339_timestamp_still_produces_attention_evidence() {
        let snapshot = with_freshness(
            parse_updates(
                "rfc3339",
                &update_line(
                    r#""2026-09-01T08:06:40Z""#,
                    r#"{"sessionUpdate":"user_message_chunk"}"#,
                ),
            ),
            unix_secs(FIXTURE_TS + 1),
        );

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS))
        );
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Fresh);
    }

    #[test]
    fn illegal_timestamp_does_not_refresh_attention_evidence() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("-1", r#"{"sessionUpdate":"agent_message_chunk"}"#),
            update_line(
                "1.5",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = parse_updates("illegal-ts", &updates);

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS)),
            "illegal timestamps must keep the previous evidence time"
        );
        assert_ne!(
            snapshot.last_attention_evidence_at,
            Some(SystemTime::UNIX_EPOCH),
            "journal mtime/fallback must not become attention evidence"
        );
    }

    #[test]
    fn unrelated_append_does_not_refresh_attention_evidence() {
        let later = FIXTURE_TS + 30;
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                &later.to_string(),
                r#"{"sessionUpdate":"session_info_update"}"#,
            ),
            update_line(
                &later.to_string(),
                r#"{"sessionUpdate":"plan","entries":[]}"#,
            ),
        ]
        .join("\n");
        let snapshot = parse_updates("unrelated", &updates);

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS))
        );
        assert_eq!(snapshot.last_source_activity_at, unix_secs(later));
    }

    #[test]
    fn user_message_is_hud_admitted_on_the_next_scan() {
        let root =
            std::env::temp_dir().join(format!("agent-observer-grok-admit-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        write_session(
            &root,
            "sess-admit",
            r"D:\work",
            &update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
        );

        let snapshots = discover_sessions_at(&root, unix_secs(FIXTURE_TS + 1));
        let snapshot = snapshots
            .iter()
            .find(|item| item.native_session_id == "sess-admit")
            .expect("session must be discovered on the next scan");

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Fresh);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS))
        );
        assert!(hud_would_admit(snapshot));
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn turn_completed_with_empty_active_set_is_result_ready() {
        let done_at = FIXTURE_TS + 87;
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                &done_at.to_string(),
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = with_freshness(parse_updates("end-empty", &updates), unix_secs(done_at + 1));

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(done_at))
        );
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Fresh);
        assert!(hud_would_admit(&snapshot));
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn turn_completed_with_active_background_task_stays_working() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250010",
                r#"{"sessionUpdate":"task_backgrounded","task_id":"task-1"}"#,
            ),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = parse_updates("end-active", &updates);

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_ne!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 87))
        );
    }

    /// A background task completion may trigger an auto-wake synthetic prompt,
    /// so it must never settle the session on its own.
    #[test]
    fn task_completed_after_end_turn_does_not_green() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250010",
                r#"{"sessionUpdate":"task_backgrounded","task_id":"task-1"}"#,
            ),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line(
                "1788250090",
                r#"{"sessionUpdate":"task_completed","task_snapshot":{"task_id":"task-1"}}"#,
            ),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("task-cleared", &updates),
            unix_secs(FIXTURE_TS + 91),
        );

        assert_eq!(
            snapshot.attention_state,
            AttentionState::Working,
            "task_completed must never produce RESULT_READY"
        );
        assert_ne!(snapshot.attention_state, AttentionState::ResultReady);
        // The completion still refreshes evidence: it is real activity.
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 90))
        );
        assert!(hud_would_admit(&snapshot));
    }

    #[test]
    fn new_turn_after_task_completed_can_become_result_ready() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250010",
                r#"{"sessionUpdate":"task_backgrounded","task_id":"task-1"}"#,
            ),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line(
                "1788250090",
                r#"{"sessionUpdate":"task_completed","task_snapshot":{"task_id":"task-1"}}"#,
            ),
            update_line("1788250095", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250100",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("task-then-new-turn", &updates),
            unix_secs(FIXTURE_TS + 101),
        );

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 100))
        );
        assert!(hud_would_admit(&snapshot));
    }

    /// The real observed order: the task completes *before* the turn ends, so
    /// the final turn_completed must still turn green promptly.
    #[test]
    fn real_order_background_then_completed_then_end_turn_is_result_ready() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250010",
                r#"{"sessionUpdate":"task_backgrounded","task_id":"task-1"}"#,
            ),
            update_line(
                "1788250015",
                r#"{"sessionUpdate":"task_completed","task_snapshot":{"task_id":"task-1"}}"#,
            ),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("real-order", &updates),
            unix_secs(FIXTURE_TS + 88),
        );

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 87))
        );
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Fresh);
        assert!(hud_would_admit(&snapshot));
    }

    // ---- active subagents -------------------------------------------------

    /// Synthetic metadata only: `subagent_id`, `child_session_id`,
    /// `parent_session_id`, `parent_prompt_id`, `subagent_type`. Never
    /// `description`, `output`, `model`, or `prompt`.
    const SUBAGENT_SPAWN: &str = r#"{"sessionUpdate":"subagent_spawned","subagent_id":"sa-1","child_session_id":"child-sess-1","parent_session_id":"sess","parent_prompt_id":"p1","subagent_type":"explore"}"#;

    fn subagent_finish(will_wake: bool) -> String {
        format!(
            r#"{{"sessionUpdate":"subagent_finished","subagent_id":"sa-1","child_session_id":"child-sess-1","status":"completed","will_wake":{will_wake}}}"#
        )
    }

    #[test]
    fn turn_completed_with_active_subagent_stays_working() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("1788250010", SUBAGENT_SPAWN),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("subagent-active", &updates),
            unix_secs(FIXTURE_TS + 88),
        );

        assert_eq!(
            snapshot.attention_state,
            AttentionState::Working,
            "an active subagent must block RESULT_READY"
        );
        assert_ne!(snapshot.attention_state, AttentionState::ResultReady);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
        assert!(hud_would_admit(&snapshot));
    }

    #[test]
    fn subagent_finished_clears_the_set_without_greening() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("1788250010", SUBAGENT_SPAWN),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line("1788250090", &subagent_finish(false)),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("subagent-finished", &updates),
            unix_secs(FIXTURE_TS + 91),
        );

        assert_eq!(
            snapshot.attention_state,
            AttentionState::Working,
            "subagent_finished must never produce RESULT_READY"
        );
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 90))
        );
    }

    #[test]
    fn subagent_finished_with_will_wake_stays_working() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("1788250010", SUBAGENT_SPAWN),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line("1788250090", &subagent_finish(true)),
        ]
        .join("\n");
        let snapshot = parse_updates("subagent-will-wake", &updates);

        assert_ne!(
            snapshot.attention_state,
            AttentionState::ResultReady,
            "will_wake=true means a new turn is coming; it must not green"
        );
        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }

    #[test]
    fn auto_wake_turn_after_subagent_finished_can_become_result_ready() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("1788250010", SUBAGENT_SPAWN),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line("1788250090", &subagent_finish(true)),
            // auto-wake synthetic prompt
            update_line("1788250095", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250100",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("subagent-auto-wake", &updates),
            unix_secs(FIXTURE_TS + 101),
        );

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 100))
        );
        assert!(hud_would_admit(&snapshot));
    }

    #[test]
    fn unknown_subagent_finished_stays_working() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line(
                "1788250090",
                r#"{"sessionUpdate":"subagent_finished","subagent_id":"ghost","child_session_id":"child-x","status":"completed","will_wake":false}"#,
            ),
        ]
        .join("\n");
        let snapshot = parse_updates("subagent-unknown", &updates);

        assert_ne!(
            snapshot.attention_state,
            AttentionState::ResultReady,
            "an untracked subagent_finished must not leave or produce green"
        );
        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }

    // ---- active scheduled tasks -------------------------------------------

    /// Synthetic metadata only: `task_id`, `human_schedule`, `next_fire_at`.
    /// The real `prompt` field is never read or stored.
    const SCHEDULE_CREATE: &str = r#"{"sessionUpdate":"scheduled_task_created","task_id":"cron-1","human_schedule":"every 5 minutes","next_fire_at":"2026-09-01T08:11:40Z"}"#;

    #[test]
    fn turn_completed_with_active_scheduled_task_stays_working() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("1788250010", SCHEDULE_CREATE),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("schedule-active", &updates),
            unix_secs(FIXTURE_TS + 88),
        );

        assert_eq!(
            snapshot.attention_state,
            AttentionState::Working,
            "an active session schedule must block RESULT_READY"
        );
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
        assert!(hud_would_admit(&snapshot));
    }

    #[test]
    fn scheduled_task_deleted_does_not_green() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("1788250010", SCHEDULE_CREATE),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line(
                "1788250090",
                r#"{"sessionUpdate":"scheduled_task_deleted","task_id":"cron-1"}"#,
            ),
        ]
        .join("\n");
        let snapshot = parse_updates("schedule-deleted", &updates);

        assert_eq!(
            snapshot.attention_state,
            AttentionState::Working,
            "scheduled_task_deleted must never produce RESULT_READY"
        );
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 90))
        );
    }

    #[test]
    fn turn_after_schedule_delete_can_become_result_ready() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("1788250010", SCHEDULE_CREATE),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line(
                "1788250090",
                r#"{"sessionUpdate":"scheduled_task_deleted","task_id":"cron-1"}"#,
            ),
            update_line("1788250095", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250100",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("schedule-then-turn", &updates),
            unix_secs(FIXTURE_TS + 101),
        );

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 100))
        );
        assert!(hud_would_admit(&snapshot));
    }

    #[test]
    fn unknown_scheduled_task_deleted_stays_working() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line(
                "1788250090",
                r#"{"sessionUpdate":"scheduled_task_deleted","task_id":"ghost-cron"}"#,
            ),
        ]
        .join("\n");
        let snapshot = parse_updates("schedule-unknown", &updates);

        assert_ne!(
            snapshot.attention_state,
            AttentionState::ResultReady,
            "an untracked scheduled_task_deleted must not leave or produce green"
        );
        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }

    #[test]
    fn subagent_spawned_and_scheduled_task_created_keep_a_settled_session_working() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line("1788250090", SUBAGENT_SPAWN),
            update_line("1788250091", SCHEDULE_CREATE),
        ]
        .join("\n");
        let snapshot = parse_updates("spawn-after-green", &updates);

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_ne!(snapshot.attention_state, AttentionState::ResultReady);
    }

    #[test]
    fn active_subagent_and_schedule_never_claim_lost() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line("1788250010", SUBAGENT_SPAWN),
            update_line("1788250011", SCHEDULE_CREATE),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        ]
        .join("\n");
        let snapshot = parse_updates("no-lost-active", &updates);

        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }

    #[test]
    fn task_complete_notification_does_not_produce_green() {
        let events = vec![
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-09-01T08:06:40Z"}"#,
            ),
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"Notification","notification_type":"task_complete","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-09-01T08:07:10Z"}"#,
            ),
        ];
        let snapshot = parse_hook_events(&events, SystemTime::UNIX_EPOCH).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_ne!(snapshot.attention_state, AttentionState::ResultReady);
    }

    #[test]
    fn idle_prompt_notification_does_not_produce_green() {
        let events = vec![
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-09-01T08:06:40Z"}"#,
            ),
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"Notification","notification_type":"idle_prompt","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-09-01T08:08:09Z"}"#,
            ),
        ];
        let snapshot = parse_hook_events(&events, SystemTime::UNIX_EPOCH).unwrap();

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_ne!(snapshot.attention_state, AttentionState::ResultReady);
    }

    #[test]
    fn cancelled_and_error_turn_completed_are_interrupted_not_green() {
        for reason in ["cancelled", "error"] {
            let updates = [
                update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
                update_line(
                    "1788250087",
                    &format!(r#"{{"sessionUpdate":"turn_completed","stop_reason":"{reason}"}}"#),
                ),
            ]
            .join("\n");
            let snapshot = parse_updates(&format!("stop-{reason}"), &updates);
            assert_eq!(
                snapshot.attention_state,
                AttentionState::Interrupted,
                "{reason} must not produce RESULT_READY"
            );
            assert_ne!(snapshot.attention_state, AttentionState::ResultReady);
        }
    }

    #[test]
    fn new_user_message_overrides_result_ready() {
        let updates = [
            update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
            update_line(
                "1788250087",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
            update_line("1788250100", r#"{"sessionUpdate":"user_message_chunk"}"#),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("new-turn", &updates),
            unix_secs(FIXTURE_TS + 101),
        );

        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(
            snapshot.last_attention_evidence_at,
            Some(unix_secs(FIXTURE_TS + 100))
        );
        assert!(hud_would_admit(&snapshot));
    }

    #[test]
    fn same_cwd_sessions_are_not_merged() {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-grok-same-cwd-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        write_session(
            &root,
            "sess-a",
            r"D:\work",
            &update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
        );
        write_session(
            &root,
            "sess-b",
            r"D:\work",
            &update_line(
                "1788250001",
                r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
            ),
        );

        let snapshots = discover_sessions_at(&root, unix_secs(FIXTURE_TS + 2));
        let ids: Vec<_> = snapshots
            .iter()
            .map(|item| item.native_session_id.as_str())
            .collect();
        assert!(ids.contains(&"sess-a"), "missing sess-a in {ids:?}");
        assert!(ids.contains(&"sess-b"), "missing sess-b in {ids:?}");
        assert_eq!(
            snapshots
                .iter()
                .filter(|item| item.cwd.as_deref() == Some(r"D:\work"))
                .count(),
            2
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn stale_freshness_does_not_overwrite_attention_state() {
        let snapshot = with_freshness(
            parse_updates(
                "stale-keep",
                &[
                    update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
                    update_line(
                        "1788250087",
                        r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#,
                    ),
                ]
                .join("\n"),
            ),
            unix_secs(FIXTURE_TS + 87 + 400),
        );

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Stale);
        assert_ne!(snapshot.attention_state, AttentionState::Unknown);
    }

    #[test]
    fn ordinary_grok_journal_never_claims_lost() {
        let snapshot = parse_updates(
            "no-lost",
            &update_line("1788250000", r#"{"sessionUpdate":"user_message_chunk"}"#),
        );
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
    }

    // ---- sticky incomplete lifecycle blockers (v1.2) ----------------------
    //
    // v1.1 proved that an unknown/missing identifier keeps `WORKING` on the
    // event itself, but it did not persist that fact. The next
    // `turn_completed(end_turn)` then saw empty active sets and greened. Every
    // case below therefore replays the gap event **and then a later
    // `turn_completed(end_turn)`**, which is the sequence that actually
    // produced the false green.
    //
    // All fixtures are synthetic and metadata-only: identifiers, `status`,
    // `will_wake`, and `human_schedule`. No prompt, description, output,
    // model, task body, or tool body appears in any fixture.

    const UNKNOWN_SUBAGENT_FINISH: &str = r#"{"sessionUpdate":"subagent_finished","subagent_id":"ghost-sa","child_session_id":"child-x","status":"completed","will_wake":false}"#;
    const MISSING_ID_SUBAGENT_FINISH: &str = r#"{"sessionUpdate":"subagent_finished","child_session_id":"child-x","status":"completed","will_wake":false}"#;
    const UNKNOWN_SCHEDULE_DELETE: &str =
        r#"{"sessionUpdate":"scheduled_task_deleted","task_id":"ghost-cron"}"#;
    const MISSING_ID_SCHEDULE_DELETE: &str = r#"{"sessionUpdate":"scheduled_task_deleted"}"#;
    const UNKNOWN_TASK_COMPLETE: &str =
        r#"{"sessionUpdate":"task_completed","task_snapshot":{"task_id":"ghost-task"}}"#;
    const MISSING_ID_TASK_COMPLETE: &str =
        r#"{"sessionUpdate":"task_completed","task_snapshot":{"status":"completed"}}"#;
    const NO_SNAPSHOT_TASK_COMPLETE: &str = r#"{"sessionUpdate":"task_completed"}"#;
    const MISSING_ID_SUBAGENT_SPAWN: &str = r#"{"sessionUpdate":"subagent_spawned","child_session_id":"child-x","subagent_type":"explore"}"#;
    const MISSING_ID_SCHEDULE_CREATE: &str =
        r#"{"sessionUpdate":"scheduled_task_created","human_schedule":"every 5 minutes"}"#;
    const MISSING_ID_TASK_BACKGROUNDED: &str = r#"{"sessionUpdate":"task_backgrounded"}"#;

    const USER_TURN: &str = r#"{"sessionUpdate":"user_message_chunk"}"#;
    const END_TURN: &str = r#"{"sessionUpdate":"turn_completed","stop_reason":"end_turn"}"#;

    const TASK_BACKGROUNDED: &str = r#"{"sessionUpdate":"task_backgrounded","task_id":"task-1"}"#;
    const TASK_COMPLETED: &str =
        r#"{"sessionUpdate":"task_completed","task_snapshot":{"task_id":"task-1"}}"#;
    const SCHEDULE_DELETED: &str =
        r#"{"sessionUpdate":"scheduled_task_deleted","task_id":"cron-1"}"#;

    fn assert_blocked_working(snapshot: &SessionSnapshot, label: &str) {
        assert_eq!(
            snapshot.attention_state,
            AttentionState::Working,
            "{label}: incomplete lifecycle evidence must keep the session WORKING"
        );
        assert_ne!(
            snapshot.attention_state,
            AttentionState::ResultReady,
            "{label}: incomplete lifecycle evidence must never produce RESULT_READY"
        );
        assert_ne!(
            snapshot.session_liveness,
            SessionLiveness::Lost,
            "{label}: an ordinary passive Grok session must never claim LOST"
        );
    }

    /// Discriminating evidence check: the sticky blocker must name the
    /// expected lifecycle class and must not mix in another class.
    fn assert_incomplete_kind(snapshot: &SessionSnapshot, kind: &str, label: &str) {
        let evidence = snapshot.attention_evidence.as_str();
        assert!(
            evidence.contains("incomplete"),
            "{label}: evidence must mention incomplete, got {evidence:?}"
        );
        assert!(
            evidence.contains(kind),
            "{label}: evidence must name the {kind} lifecycle, got {evidence:?}"
        );
        let others: &[&str] = match kind {
            "background task" => &["subagent", "scheduled task"],
            "subagent" => &["background task", "scheduled task"],
            "scheduled task" => &["background task", "subagent"],
            other => panic!("{label}: unknown lifecycle kind {other}"),
        };
        for other in others {
            assert!(
                !evidence.contains(other),
                "{label}: evidence must not mix in {other}, got {evidence:?}"
            );
        }
    }

    /// Replays one lifecycle-gap event and then a **later**
    /// `turn_completed(end_turn)`. Asserting only on the gap event itself is
    /// exactly what let the v1.1 false green through review.
    fn replay_gap_then_later_turn_completed(label: &str, gap_event: &str) -> SessionSnapshot {
        let updates = [
            update_line("1788250000", USER_TURN),
            update_line("1788250010", gap_event),
            update_line("1788250100", END_TURN),
        ]
        .join("\n");
        parse_updates(label, &updates)
    }

    #[test]
    fn unknown_subagent_finish_then_later_turn_completed_stays_working() {
        let snapshot = replay_gap_then_later_turn_completed(
            "unknown-subagent-then-turn",
            UNKNOWN_SUBAGENT_FINISH,
        );
        assert_blocked_working(&snapshot, "unknown subagent_finished then turn_completed");
        assert_incomplete_kind(
            &snapshot,
            "subagent",
            "unknown subagent_finished then turn_completed",
        );
    }

    #[test]
    fn missing_subagent_finish_id_then_later_turn_completed_stays_working() {
        let snapshot = replay_gap_then_later_turn_completed(
            "missing-subagent-id-then-turn",
            MISSING_ID_SUBAGENT_FINISH,
        );
        assert_blocked_working(
            &snapshot,
            "subagent_finished without subagent_id then turn_completed",
        );
        assert_incomplete_kind(
            &snapshot,
            "subagent",
            "subagent_finished without subagent_id then turn_completed",
        );
    }

    #[test]
    fn unknown_schedule_delete_then_later_turn_completed_stays_working() {
        let snapshot = replay_gap_then_later_turn_completed(
            "unknown-schedule-then-turn",
            UNKNOWN_SCHEDULE_DELETE,
        );
        assert_blocked_working(
            &snapshot,
            "unknown scheduled_task_deleted then turn_completed",
        );
        assert_incomplete_kind(
            &snapshot,
            "scheduled task",
            "unknown scheduled_task_deleted then turn_completed",
        );
    }

    #[test]
    fn missing_schedule_delete_id_then_later_turn_completed_stays_working() {
        let snapshot = replay_gap_then_later_turn_completed(
            "missing-schedule-id-then-turn",
            MISSING_ID_SCHEDULE_DELETE,
        );
        assert_blocked_working(
            &snapshot,
            "scheduled_task_deleted without task_id then turn_completed",
        );
        assert_incomplete_kind(
            &snapshot,
            "scheduled task",
            "scheduled_task_deleted without task_id then turn_completed",
        );
    }

    #[test]
    fn unknown_background_task_completion_then_later_turn_completed_stays_working() {
        let snapshot = replay_gap_then_later_turn_completed(
            "unknown-task-complete-then-turn",
            UNKNOWN_TASK_COMPLETE,
        );
        assert_blocked_working(&snapshot, "unknown task_completed then turn_completed");
        assert_incomplete_kind(
            &snapshot,
            "background task",
            "unknown task_completed then turn_completed",
        );
    }

    #[test]
    fn missing_background_task_completion_id_then_later_turn_completed_stays_working() {
        for (label, event) in [
            ("no-task-id", MISSING_ID_TASK_COMPLETE),
            ("no-task-snapshot", NO_SNAPSHOT_TASK_COMPLETE),
        ] {
            let snapshot =
                replay_gap_then_later_turn_completed(&format!("missing-task-id-{label}"), event);
            assert_blocked_working(
                &snapshot,
                &format!("task_completed without a usable task_id ({label}) then turn_completed"),
            );
            assert_incomplete_kind(
                &snapshot,
                "background task",
                &format!("task_completed without a usable task_id ({label}) then turn_completed"),
            );
        }
    }

    #[test]
    fn missing_subagent_spawn_id_blocks_later_turn_completion() {
        let snapshot = replay_gap_then_later_turn_completed(
            "missing-spawn-id-then-turn",
            MISSING_ID_SUBAGENT_SPAWN,
        );
        assert_blocked_working(
            &snapshot,
            "subagent_spawned without subagent_id then turn_completed",
        );
        assert_incomplete_kind(
            &snapshot,
            "subagent",
            "subagent_spawned without subagent_id then turn_completed",
        );
    }

    #[test]
    fn missing_schedule_create_id_blocks_later_turn_completion() {
        let snapshot = replay_gap_then_later_turn_completed(
            "missing-schedule-create-id-then-turn",
            MISSING_ID_SCHEDULE_CREATE,
        );
        assert_blocked_working(
            &snapshot,
            "scheduled_task_created without task_id then turn_completed",
        );
        assert_incomplete_kind(
            &snapshot,
            "scheduled task",
            "scheduled_task_created without task_id then turn_completed",
        );
    }

    #[test]
    fn missing_background_task_id_blocks_later_turn_completion() {
        let snapshot = replay_gap_then_later_turn_completed(
            "missing-background-id-then-turn",
            MISSING_ID_TASK_BACKGROUNDED,
        );
        assert_blocked_working(
            &snapshot,
            "task_backgrounded without task_id then turn_completed",
        );
        assert_incomplete_kind(
            &snapshot,
            "background task",
            "task_backgrounded without task_id then turn_completed",
        );
    }

    /// A new user turn must not clear the blocker: a subagent, background
    /// task, or schedule can outlive the turn that observed the gap.
    #[test]
    fn incomplete_lifecycle_blocker_survives_a_new_user_turn() {
        let updates = [
            update_line("1788250000", USER_TURN),
            update_line("1788250010", UNKNOWN_SUBAGENT_FINISH),
            update_line("1788250020", USER_TURN),
            update_line("1788250030", END_TURN),
            update_line("1788250040", USER_TURN),
            update_line("1788250050", END_TURN),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("blocker-survives-new-turn", &updates),
            unix_secs(FIXTURE_TS + 51),
        );

        assert_blocked_working(&snapshot, "blocker must survive two more user turns");
        assert_incomplete_kind(
            &snapshot,
            "subagent",
            "blocker must still name the subagent lifecycle after later turns",
        );
        assert_eq!(
            snapshot.evidence_freshness,
            EvidenceFreshness::Fresh,
            "freshness must stay independent of the blocker"
        );
    }

    /// Compaction completion must not be a side door around the blocker.
    ///
    /// The sequence is discriminating only if `turn_completed(end_turn)` has
    /// already matched `ended_turn_seq` and every active set is empty. Without
    /// that later turn end, `can_settle()` is already false, so the test would
    /// not prove the incomplete blocker is what blocks compaction green.
    #[test]
    fn incomplete_lifecycle_blocks_compaction_completion_green() {
        for event in [
            "auto_compact_completed",
            "auto_compact_failed",
            "auto_compact_cancelled",
        ] {
            let updates = [
                update_line("1788250000", USER_TURN),
                update_line("1788250010", UNKNOWN_TASK_COMPLETE),
                update_line("1788250020", END_TURN),
                update_line("1788250030", r#"{"sessionUpdate":"auto_compact_started"}"#),
                update_line("1788250040", &format!(r#"{{"sessionUpdate":"{event}"}}"#)),
            ]
            .join("\n");
            let snapshot = parse_updates(&format!("blocker-compact-{event}"), &updates);
            assert_blocked_working(
                &snapshot,
                &format!("{event} must not bypass an incomplete lifecycle blocker"),
            );
            assert_incomplete_kind(
                &snapshot,
                "background task",
                &format!("{event} must keep the background-task incomplete blocker"),
            );
        }
    }

    #[test]
    fn fully_tracked_background_task_can_still_settle() {
        let updates = [
            update_line("1788250000", USER_TURN),
            update_line("1788250010", TASK_BACKGROUNDED),
            update_line("1788250020", TASK_COMPLETED),
            update_line("1788250087", END_TURN),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("tracked-task-settles", &updates),
            unix_secs(FIXTURE_TS + 88),
        );

        assert_eq!(
            snapshot.attention_state,
            AttentionState::ResultReady,
            "a fully tracked background task must still be able to settle"
        );
        assert_eq!(snapshot.attention_evidence, SETTLE_EVIDENCE);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn fully_tracked_subagent_can_still_settle() {
        let updates = [
            update_line("1788250000", USER_TURN),
            update_line("1788250010", SUBAGENT_SPAWN),
            update_line("1788250087", END_TURN),
            update_line("1788250090", &subagent_finish(false)),
            // auto-wake turn driven by the subagent completion
            update_line("1788250095", USER_TURN),
            update_line("1788250100", END_TURN),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("tracked-subagent-settles", &updates),
            unix_secs(FIXTURE_TS + 101),
        );

        assert_eq!(
            snapshot.attention_state,
            AttentionState::ResultReady,
            "a fully tracked subagent must still be able to settle"
        );
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn fully_tracked_schedule_can_still_settle() {
        let updates = [
            update_line("1788250000", USER_TURN),
            update_line("1788250010", SCHEDULE_CREATE),
            update_line("1788250087", END_TURN),
            update_line("1788250090", SCHEDULE_DELETED),
            update_line("1788250095", USER_TURN),
            update_line("1788250100", END_TURN),
        ]
        .join("\n");
        let snapshot = with_freshness(
            parse_updates("tracked-schedule-settles", &updates),
            unix_secs(FIXTURE_TS + 101),
        );

        assert_eq!(
            snapshot.attention_state,
            AttentionState::ResultReady,
            "a fully tracked schedule must still be able to settle"
        );
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
    }

    #[test]
    fn ordinary_empty_turn_can_still_settle() {
        let snapshot = with_freshness(
            parse_updates(
                "ordinary-empty-turn",
                &[
                    update_line("1788250000", USER_TURN),
                    update_line("1788250087", END_TURN),
                ]
                .join("\n"),
            ),
            unix_secs(FIXTURE_TS + 88),
        );

        assert_eq!(snapshot.attention_state, AttentionState::ResultReady);
        assert_eq!(snapshot.attention_evidence, SETTLE_EVIDENCE);
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
        assert!(hud_would_admit(&snapshot));
    }

    /// The hook `Stop` path is a separate source and is never overridden by
    /// the passive journal's incomplete-evidence state.
    #[test]
    fn hook_stop_with_explicit_empty_arrays_can_still_settle() {
        let events = vec![
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"UserPromptSubmit","session_id":"grok-1","prompt_id":"p1","observed_at_utc":"2026-09-01T08:06:40Z"}"#,
            ),
            value(
                r#"{"observer_schema":1,"source":"grok-hook","event":"Stop","reason":"end_turn","session_id":"grok-1","prompt_id":"p1","background_tasks":[],"session_crons":[],"observed_at_utc":"2026-09-01T08:07:10Z"}"#,
            ),
        ];
        let snapshot = parse_hook_events(&events, SystemTime::UNIX_EPOCH).unwrap();

        assert_eq!(
            snapshot.attention_state,
            AttentionState::ResultReady,
            "an explicit hook Stop with two empty arrays must still green"
        );
        assert_ne!(snapshot.session_liveness, SessionLiveness::Lost);
    }
}
