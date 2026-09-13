use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::time::SystemTime;

use serde_json::Value;

use crate::model::{AgentFamily, HostLiveness, SessionSnapshot, Surface};
use crate::process::query_process_start_filetime;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistryHostStatus {
    Alive,
    Dead,
    Unreachable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaudeDesktopHostBinding {
    pub native_session_id: String,
    pub cwd: Option<String>,
    pub process_id: u32,
    pub process_started_filetime: u64,
    pub status: RegistryHostStatus,
}

pub fn inspect_pid_registry(root: &Path) -> Vec<ClaudeDesktopHostBinding> {
    inspect_pid_registry_with(root, query_process_start_filetime)
}

pub fn apply_pid_registry(root: &Path, snapshots: &mut [SessionSnapshot], now: SystemTime) {
    let bindings = inspect_pid_registry(root);
    apply_bindings(&bindings, snapshots, now);
}

fn inspect_pid_registry_with(
    root: &Path,
    mut query: impl FnMut(u32) -> Result<Option<u64>, String>,
) -> Vec<ClaudeDesktopHostBinding> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut bindings = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let Some((native_session_id, cwd, process_id, expected_filetime)) =
            parse_registry_file(&path)
        else {
            continue;
        };
        let status = match query(process_id) {
            Ok(Some(actual)) if actual == expected_filetime => RegistryHostStatus::Alive,
            Ok(Some(_)) | Ok(None) => RegistryHostStatus::Dead,
            Err(_) => RegistryHostStatus::Unreachable,
        };
        bindings.push(ClaudeDesktopHostBinding {
            native_session_id,
            cwd,
            process_id,
            process_started_filetime: expected_filetime,
            status,
        });
    }
    bindings
}

fn parse_registry_file(path: &Path) -> Option<(String, Option<String>, u32, u64)> {
    let text = fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    if value.get("entrypoint").and_then(Value::as_str) != Some("claude-desktop") {
        return None;
    }
    let native_session_id = nonempty_string(&value, "sessionId")?;
    let process_id = u32::try_from(value.get("pid")?.as_u64()?).ok()?;
    if path.file_stem().and_then(|name| name.to_str()) != Some(process_id.to_string().as_str()) {
        return None;
    }
    let process_started_filetime = value.get("procStart").and_then(|raw| {
        raw.as_str()
            .and_then(|value| value.parse().ok())
            .or_else(|| raw.as_u64())
    })?;
    Some((
        native_session_id,
        nonempty_string(&value, "cwd"),
        process_id,
        process_started_filetime,
    ))
}

fn apply_bindings(
    bindings: &[ClaudeDesktopHostBinding],
    snapshots: &mut [SessionSnapshot],
    now: SystemTime,
) {
    let mut by_session: BTreeMap<&str, Vec<&ClaudeDesktopHostBinding>> = BTreeMap::new();
    for binding in bindings {
        by_session
            .entry(binding.native_session_id.as_str())
            .or_default()
            .push(binding);
    }
    for snapshot in snapshots.iter_mut().filter(|snapshot| {
        snapshot.family == AgentFamily::Claude && snapshot.surface == Surface::Desktop
    }) {
        let Some(candidates) = by_session.get(snapshot.native_session_id.as_str()) else {
            continue;
        };
        let binding = candidates
            .iter()
            .copied()
            .find(|binding| binding.status == RegistryHostStatus::Alive)
            .or_else(|| {
                candidates
                    .iter()
                    .copied()
                    .find(|binding| binding.status == RegistryHostStatus::Unreachable)
            })
            .unwrap_or(candidates[0]);
        let (status, detail) = match binding.status {
            RegistryHostStatus::Alive => (HostLiveness::Alive, "is alive with matching FILETIME"),
            RegistryHostStatus::Dead => (
                HostLiveness::Dead,
                "is absent or its FILETIME no longer matches; session state is not inferred",
            ),
            RegistryHostStatus::Unreachable => (
                HostLiveness::Unreachable,
                "could not be queried; session state is not inferred",
            ),
        };
        snapshot.set_host_liveness(
            status,
            format!(
                "Claude Desktop PID registry: exact session host PID {} {detail}",
                binding.process_id
            ),
            now,
        );
    }
}

fn nonempty_string(value: &Value, field: &str) -> Option<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AttentionState, SessionLiveness};
    use std::time::Duration;

    fn write_registry(root: &Path, pid: u32, entrypoint: &str, filetime: u64) {
        fs::create_dir_all(root).unwrap();
        fs::write(
            root.join(format!("{pid}.json")),
            serde_json::json!({
                "pid": pid,
                "sessionId": "desktop-session",
                "cwd": "D:\\ProjectA",
                "entrypoint": entrypoint,
                "procStart": filetime.to_string()
            })
            .to_string(),
        )
        .unwrap();
    }

    fn snapshot(at: SystemTime) -> SessionSnapshot {
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Claude,
            Surface::Desktop,
            "desktop-session".to_string(),
            Some("D:\\ProjectA".to_string()),
            "journal".to_string(),
            at,
        );
        snapshot.set_attention(AttentionState::Working, "journal event", Some(at));
        snapshot
    }

    #[test]
    fn exact_registry_filetime_sets_host_alive_without_inferring_session() {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-claude-registry-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        write_registry(&root, 42, "claude-desktop", 1234);
        let bindings = inspect_pid_registry_with(&root, |pid| {
            assert_eq!(pid, 42);
            Ok(Some(1234))
        });
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(100);
        let mut snapshots = vec![snapshot(now)];
        apply_bindings(&bindings, &mut snapshots, now);

        assert_eq!(snapshots[0].host_liveness, HostLiveness::Alive);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Unknown);
        assert_eq!(snapshots[0].attention_state, AttentionState::Working);
        assert!(
            snapshots[0]
                .host_liveness_evidence
                .as_deref()
                .unwrap()
                .contains("matching FILETIME")
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn pid_reuse_sets_exact_host_dead_but_never_session_lost() {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-claude-registry-reuse-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        write_registry(&root, 43, "claude-desktop", 1234);
        let bindings = inspect_pid_registry_with(&root, |_| Ok(Some(9999)));
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(100);
        let mut snapshots = vec![snapshot(now)];
        apply_bindings(&bindings, &mut snapshots, now);

        assert_eq!(snapshots[0].host_liveness, HostLiveness::Dead);
        assert_eq!(snapshots[0].session_liveness, SessionLiveness::Unknown);
        assert_ne!(snapshots[0].session_liveness, SessionLiveness::Lost);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn ignores_non_desktop_registry_entries() {
        let root = std::env::temp_dir().join(format!(
            "agent-observer-claude-registry-cli-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        write_registry(&root, 44, "cli", 1234);
        assert!(inspect_pid_registry_with(&root, |_| Ok(Some(1234))).is_empty());
        let _ = fs::remove_dir_all(root);
    }
}
