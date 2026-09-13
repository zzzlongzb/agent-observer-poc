use std::process::Command;
use std::time::SystemTime;

use crate::model::system_time_from_unix_millis;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProcessIdentity {
    pub process_id: u32,
    pub started_at: SystemTime,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessObservation {
    Alive,
    Missing,
    CreationTimeMismatch { actual_started_at: SystemTime },
    Unreachable(String),
}

impl ProcessObservation {
    #[allow(dead_code)]
    pub fn our_process_is_running(&self) -> bool {
        matches!(self, Self::Alive)
    }

    #[allow(dead_code)]
    pub fn our_process_is_absent(&self) -> bool {
        matches!(self, Self::Missing | Self::CreationTimeMismatch { .. })
    }
}

pub fn observe_expected(process_id: u32, expected_started_at: SystemTime) -> ProcessObservation {
    match query_process(process_id) {
        Ok(None) => ProcessObservation::Missing,
        Ok(Some(identity)) => {
            if identity.started_at == expected_started_at {
                ProcessObservation::Alive
            } else {
                ProcessObservation::CreationTimeMismatch {
                    actual_started_at: identity.started_at,
                }
            }
        }
        Err(message) => ProcessObservation::Unreachable(message),
    }
}

pub fn query_process(process_id: u32) -> Result<Option<ProcessIdentity>, String> {
    #[cfg(target_os = "windows")]
    {
        query_windows_process(process_id)
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = process_id;
        Err("process observation is only implemented for Windows".to_string())
    }
}

pub fn query_process_start_filetime(process_id: u32) -> Result<Option<u64>, String> {
    #[cfg(target_os = "windows")]
    {
        let script = format!(
            "$ErrorActionPreference='SilentlyContinue'; $p = Get-Process -Id {process_id}; if ($p) {{ [uint64]$p.StartTime.ToFileTimeUtc() }}"
        );
        let mut command = Command::new("powershell.exe");
        command.args(["-NoProfile", "-NonInteractive", "-Command", &script]);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let output = command.output().map_err(|error| {
            format!("host process FILETIME query could not start PowerShell: {error}")
        })?;
        let trimmed = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if trimmed.is_empty() {
            return Ok(None);
        }
        return trimmed
            .parse::<u64>()
            .map(Some)
            .map_err(|_| format!("host process FILETIME query returned a non-integer: {trimmed}"));
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = process_id;
        Err("process FILETIME observation is only implemented for Windows".to_string())
    }
}

#[cfg(target_os = "windows")]
fn query_windows_process(process_id: u32) -> Result<Option<ProcessIdentity>, String> {
    let script = format!(
        "$ErrorActionPreference='SilentlyContinue'; $p = Get-Process -Id {process_id}; if ($p) {{ [int64]([DateTimeOffset]$p.StartTime).ToUnixTimeMilliseconds() }}"
    );
    let mut command = Command::new("powershell.exe");
    command.args(["-NoProfile", "-NonInteractive", "-Command", &script]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let output = command
        .output()
        .map_err(|error| format!("host process query could not start PowerShell: {error}"))?;
    let text = String::from_utf8_lossy(&output.stdout);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    let millis = trimmed
        .parse::<u128>()
        .map_err(|_| format!("host process query returned a non-integer start time: {trimmed}"))?;
    let started_at = system_time_from_unix_millis(millis)
        .ok_or_else(|| "host process query start time is out of range".to_string())?;
    Ok(Some(ProcessIdentity {
        process_id,
        started_at,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::unix_millis;
    use std::time::Duration;

    #[test]
    fn creation_time_mismatch_is_not_treated_as_our_alive_process() {
        let expected = SystemTime::UNIX_EPOCH + Duration::from_millis(1000);
        let actual = SystemTime::UNIX_EPOCH + Duration::from_millis(2000);
        let observation = ProcessObservation::CreationTimeMismatch {
            actual_started_at: actual,
        };

        assert!(!observation.our_process_is_running());
        assert!(observation.our_process_is_absent());
        assert_ne!(expected, actual);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn current_process_start_time_round_trips_and_rejects_other_creation_times() {
        let process_id = std::process::id();
        let identity = query_process(process_id)
            .expect("query current test process")
            .expect("current test process must exist");

        assert_eq!(
            observe_expected(process_id, identity.started_at),
            ProcessObservation::Alive
        );
        assert_eq!(
            observe_expected(process_id, SystemTime::UNIX_EPOCH),
            ProcessObservation::CreationTimeMismatch {
                actual_started_at: identity.started_at,
            }
        );
        assert!(unix_millis(identity.started_at) > 0);
        assert!(
            query_process_start_filetime(process_id)
                .expect("query current process FILETIME")
                .is_some()
        );
    }
}
