use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

use crate::claude_desktop::{RegistryHostStatus, inspect_pid_registry};
use crate::host::inspect_windows_desktop_hosts;

pub struct DoctorOptions {
    pub codex_root: PathBuf,
    pub claude_root: PathBuf,
    pub claude_session_root: PathBuf,
    pub claude_hook_root: PathBuf,
    pub pi_session_root: PathBuf,
    pub pi_hook_root: PathBuf,
    pub pi_bridge: PathBuf,
    pub grok_session_root: PathBuf,
    pub grok_hook_root: PathBuf,
    pub grok_bridge: PathBuf,
    pub runtime_binding_root: PathBuf,
    pub codex_executable: PathBuf,
    pub claude_executable: PathBuf,
    pub pi_executable: PathBuf,
    pub grok_executable: PathBuf,
}

pub fn report(options: &DoctorOptions) -> Value {
    let desktop = inspect_windows_desktop_hosts();
    let claude_bindings = inspect_pid_registry(&options.claude_session_root);
    let alive_claude_bindings = claude_bindings
        .iter()
        .filter(|binding| binding.status == RegistryHostStatus::Alive)
        .count();
    serde_json::json!({
        "observer_schema": 1,
        "record_type": "doctor",
        "paths": {
            "codex_sessions": path_status(&options.codex_root),
            "claude_projects": path_status(&options.claude_root),
            "claude_pid_sessions": path_status(&options.claude_session_root),
            "claude_hooks": path_status(&options.claude_hook_root),
            "pi_sessions": path_status(&options.pi_session_root),
            "pi_hooks": path_status(&options.pi_hook_root),
            "pi_bridge": path_status(&options.pi_bridge),
            "grok_sessions": path_status(&options.grok_session_root),
            "grok_hooks": path_status(&options.grok_hook_root),
            "grok_bridge": path_status(&options.grok_bridge),
            "runtime_bindings": path_status(&options.runtime_binding_root),
        },
        "versions": {
            "codex": command_version(&options.codex_executable),
            "claude": command_version(&options.claude_executable),
            "pi": command_version(&options.pi_executable),
            "grok": command_version(&options.grok_executable),
        },
        "desktop_hosts": {
            "codex_family": desktop.codex.to_string(),
            "claude_family": desktop.claude.to_string(),
            "evidence": desktop.evidence,
            "claude_exact_alive_pid_bindings": alive_claude_bindings,
        },
        "surface_capabilities": {
            "codex_cli": "EXACT_WHEN_OBSERVER_OWNED",
            "claude_cli": "EXACT_WHEN_OBSERVER_OWNED",
            "codex_desktop": "PARTIAL",
            "claude_desktop": "PARTIAL_PID_HOST_ONLY",
            "pi_cli": "PASSIVE_JOURNAL_PLUS_EXTENSION",
            "grok_build_cli": "PASSIVE_SESSION_PLUS_HOOK",
        },
        "safety": {
            "desktop_session_lost_enabled": false,
            "reads_claude_session_keys": false,
            "desktop_ipc_attach_enabled": false,
            "ordinary_tui_session_lost_enabled": false,
        }
    })
}

pub fn print_human(report: &Value) {
    println!("Agent Observer doctor");
    println!();
    println!("Paths");
    if let Some(paths) = report.get("paths").and_then(Value::as_object) {
        for (name, value) in paths {
            let path = value.get("path").and_then(Value::as_str).unwrap_or("?");
            let exists = value
                .get("exists")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            println!(
                "  {name}: {} ({})",
                if exists { "OK" } else { "MISSING" },
                path
            );
        }
    }
    println!();
    println!("Versions");
    if let Some(versions) = report.get("versions").and_then(Value::as_object) {
        for (name, value) in versions {
            let status = value
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let version = value.get("version").and_then(Value::as_str).unwrap_or("");
            println!("  {name}: {status} {version}");
        }
    }
    println!();
    println!("Capabilities");
    if let Some(capabilities) = report
        .get("surface_capabilities")
        .and_then(Value::as_object)
    {
        for (name, value) in capabilities {
            println!("  {name}: {}", value.as_str().unwrap_or("UNKNOWN"));
        }
    }
    println!();
    println!("Desktop IPC attach: disabled");
    println!("Desktop per-session LOST: disabled");
}

fn path_status(path: &Path) -> Value {
    let metadata = std::fs::metadata(path).ok();
    serde_json::json!({
        "path": path.to_string_lossy(),
        "exists": metadata.is_some(),
        "is_directory": metadata.as_ref().is_some_and(|value| value.is_dir()),
        "read_only": metadata.as_ref().is_some_and(|value| value.permissions().readonly()),
    })
}

fn command_version(executable: &Path) -> Value {
    match Command::new(executable).arg("--version").output() {
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            serde_json::json!({
                "executable": executable.to_string_lossy(),
                "status": if output.status.success() { "OK" } else { "ERROR" },
                "version": if stdout.is_empty() { stderr } else { stdout },
                "exit_code": output.status.code(),
            })
        }
        Err(error) => serde_json::json!({
            "executable": executable.to_string_lossy(),
            "status": "UNAVAILABLE",
            "version": null,
            "error": error.to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_status_is_read_only_and_does_not_create_the_path() {
        let path = std::env::temp_dir().join(format!(
            "agent-observer-doctor-missing-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        let status = path_status(&path);

        assert_eq!(status["exists"], false);
        assert!(!path.exists());
    }
}
