use std::collections::BTreeSet;
use std::process::Command;
use std::time::SystemTime;

use crate::model::{AgentFamily, HostLiveness, SessionSnapshot, Surface};

pub fn apply_desktop_host_liveness(snapshots: &mut [SessionSnapshot], now: SystemTime) {
    if !snapshots
        .iter()
        .any(|snapshot| snapshot.surface == Surface::Desktop)
    {
        return;
    }
    let observation = inspect_windows_desktop_hosts();
    for snapshot in snapshots
        .iter_mut()
        .filter(|snapshot| snapshot.surface == Surface::Desktop)
    {
        let (liveness, evidence) = match snapshot.family {
            AgentFamily::Codex => observation.for_family(AgentFamily::Codex),
            AgentFamily::Claude => observation.for_family(AgentFamily::Claude),
            // Pi has no Desktop surface; snapshots are CLI-only and never
            // reach this Desktop host scan.
            AgentFamily::Pi => (
                HostLiveness::Unknown,
                "Pi is a CLI-only surface; the Desktop host scan does not apply".to_string(),
            ),
            AgentFamily::Grok => (
                HostLiveness::Unknown,
                "Grok is a CLI-only surface; the Desktop host scan does not apply".to_string(),
            ),
        };
        snapshot.set_host_liveness(liveness, evidence, now);
    }
}

pub struct DesktopHostObservation {
    pub codex: HostLiveness,
    pub claude: HostLiveness,
    pub evidence: String,
}

impl DesktopHostObservation {
    fn for_family(&self, family: AgentFamily) -> (HostLiveness, String) {
        let liveness = match family {
            AgentFamily::Codex => self.codex,
            AgentFamily::Claude => self.claude,
            // Pi is never a Desktop host; its exact liveness comes from the
            // owned RPC child PID + creation time, not a family process scan.
            AgentFamily::Pi => HostLiveness::Unknown,
            AgentFamily::Grok => HostLiveness::Unknown,
        };
        (liveness, self.evidence.clone())
    }
}

pub fn inspect_windows_desktop_hosts() -> DesktopHostObservation {
    #[cfg(target_os = "windows")]
    {
        // `tasklist` is denied in this user context. The PowerShell cmdlet is
        // read-only and returns just process names, which is enough for this
        // family-level host signal.
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;

        let mut command = Command::new("powershell.exe");
        command
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Get-Process -Name Codex,Claude -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName",
            ])
            .creation_flags(CREATE_NO_WINDOW);
        let output = command.output();
        let Ok(output) = output else {
            return DesktopHostObservation {
                codex: HostLiveness::Unreachable,
                claude: HostLiveness::Unreachable,
                evidence: "host process scan: PowerShell Get-Process could not be started"
                    .to_string(),
            };
        };
        if !output.status.success() {
            return DesktopHostObservation {
                codex: HostLiveness::Unreachable,
                claude: HostLiveness::Unreachable,
                evidence: "host process scan: PowerShell Get-Process did not complete".to_string(),
            };
        }

        let process_names = parse_process_names(&String::from_utf8_lossy(&output.stdout));
        return DesktopHostObservation {
            codex: process_liveness(&process_names, "codex"),
            claude: process_liveness(&process_names, "claude"),
            evidence: "host process scan: PowerShell Get-Process (family-level only)".to_string(),
        };
    }

    #[cfg(not(target_os = "windows"))]
    DesktopHostObservation {
        codex: HostLiveness::Unreachable,
        claude: HostLiveness::Unreachable,
        evidence: "host process scan is only implemented for Windows".to_string(),
    }
}

fn process_liveness(process_names: &BTreeSet<String>, expected: &str) -> HostLiveness {
    if process_names.contains(expected) {
        HostLiveness::Alive
    } else {
        HostLiveness::Dead
    }
}

fn parse_process_names(output: &str) -> BTreeSet<String> {
    output
        .lines()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(|name| name.to_ascii_lowercase())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AgentFamily, AttentionState, EvidenceFreshness, SessionLiveness};

    #[test]
    fn process_scan_output_identifies_desktop_process_names() {
        let names = parse_process_names("claude\nCodex\nOther");

        assert_eq!(process_liveness(&names, "codex"), HostLiveness::Alive);
        assert_eq!(process_liveness(&names, "claude"), HostLiveness::Alive);
    }

    #[test]
    fn family_level_host_dead_does_not_mark_an_unbound_session_lost() {
        let now = SystemTime::now();
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Codex,
            Surface::Desktop,
            "desktop-1".to_string(),
            None,
            "journal".to_string(),
            now,
        );
        snapshot.set_attention(AttentionState::Working, "task_started", Some(now));
        snapshot.apply_evidence_freshness(now, std::time::Duration::from_secs(300));
        snapshot.set_host_liveness(HostLiveness::Dead, "family-level scan", now);

        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Fresh);
        assert_eq!(snapshot.attention_state, AttentionState::Working);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }
}
