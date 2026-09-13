use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum AgentFamily {
    Codex,
    Claude,
    Pi,
    Grok,
}

impl fmt::Display for AgentFamily {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Codex => f.write_str("Codex"),
            Self::Claude => f.write_str("Claude"),
            Self::Pi => f.write_str("Pi"),
            Self::Grok => f.write_str("Grok"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Surface {
    Desktop,
    Cli,
    Unknown,
}

impl fmt::Display for Surface {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Desktop => f.write_str("Desktop"),
            Self::Cli => f.write_str("CLI"),
            Self::Unknown => f.write_str("Unknown surface"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttentionState {
    Working,
    NeedsMe,
    ResultReady,
    Interrupted,
    Unknown,
}

impl fmt::Display for AttentionState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Working => f.write_str("WORKING"),
            Self::NeedsMe => f.write_str("NEEDS_ME"),
            Self::ResultReady => f.write_str("RESULT_READY"),
            Self::Interrupted => f.write_str("INTERRUPTED"),
            Self::Unknown => f.write_str("UNKNOWN"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EvidenceFreshness {
    Fresh,
    Aging,
    Stale,
    None,
}

impl fmt::Display for EvidenceFreshness {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Fresh => f.write_str("FRESH"),
            Self::Aging => f.write_str("AGING"),
            Self::Stale => f.write_str("STALE"),
            Self::None => f.write_str("NONE"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostLiveness {
    Alive,
    Dead,
    Unreachable,
    Unknown,
}

impl fmt::Display for HostLiveness {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Alive => f.write_str("ALIVE"),
            Self::Dead => f.write_str("DEAD"),
            Self::Unreachable => f.write_str("UNREACHABLE"),
            Self::Unknown => f.write_str("UNKNOWN"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionLiveness {
    LiveActive,
    LiveIdle,
    Detached,
    Lost,
    Unknown,
}

impl fmt::Display for SessionLiveness {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::LiveActive => f.write_str("LIVE_ACTIVE"),
            Self::LiveIdle => f.write_str("LIVE_IDLE"),
            Self::Detached => f.write_str("DETACHED"),
            Self::Lost => f.write_str("LOST"),
            Self::Unknown => f.write_str("UNKNOWN"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeBinding {
    pub runtime_binding_id: String,
    pub native_session_id: String,
    pub active_runtime_id: String,
    pub host_instance_id: String,
    pub process_id: u32,
    pub process_started_at: SystemTime,
    pub active_observed_at: SystemTime,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AbnormalRuntimeExit {
    pub runtime_binding_id: String,
    pub native_session_id: String,
    pub active_runtime_id: String,
    pub host_instance_id: String,
    pub process_id: u32,
    pub process_started_at: SystemTime,
    pub observed_at: SystemTime,
}

impl RuntimeBinding {
    pub fn is_exact_active(&self) -> bool {
        !self.runtime_binding_id.is_empty()
            && !self.native_session_id.is_empty()
            && !self.active_runtime_id.is_empty()
            && !self.host_instance_id.is_empty()
            && self.process_id != 0
    }

    pub fn matches_abnormal_exit(&self, exit: &AbnormalRuntimeExit) -> bool {
        self.is_exact_active()
            && self.runtime_binding_id == exit.runtime_binding_id
            && self.native_session_id == exit.native_session_id
            && self.active_runtime_id == exit.active_runtime_id
            && self.host_instance_id == exit.host_instance_id
            && self.process_id == exit.process_id
            && self.process_started_at == exit.process_started_at
    }

    pub fn to_abnormal_exit(&self, observed_at: SystemTime) -> Option<AbnormalRuntimeExit> {
        if !self.is_exact_active() {
            return None;
        }
        Some(AbnormalRuntimeExit {
            runtime_binding_id: self.runtime_binding_id.clone(),
            native_session_id: self.native_session_id.clone(),
            active_runtime_id: self.active_runtime_id.clone(),
            host_instance_id: self.host_instance_id.clone(),
            process_id: self.process_id,
            process_started_at: self.process_started_at,
            observed_at,
        })
    }
}

#[derive(Debug, Clone)]
pub struct SessionSnapshot {
    pub family: AgentFamily,
    pub surface: Surface,
    pub native_session_id: String,
    pub cwd: Option<String>,
    pub attention_state: AttentionState,
    pub attention_evidence: String,
    pub evidence_freshness: EvidenceFreshness,
    pub host_liveness: HostLiveness,
    pub host_liveness_evidence: Option<String>,
    pub session_liveness: SessionLiveness,
    pub session_liveness_evidence: Option<String>,
    pub runtime_binding_id: Option<String>,
    pub active_runtime_id: Option<String>,
    pub runtime_binding: Option<RuntimeBinding>,
    pub source: String,
    pub last_attention_evidence_at: Option<SystemTime>,
    pub last_session_liveness_evidence_at: Option<SystemTime>,
    pub last_host_liveness_observed_at: Option<SystemTime>,
    pub last_source_activity_at: SystemTime,
    pub last_observed_at: SystemTime,
    /// Optional presentation-only label. Never used as identity, attention,
    /// freshness, or liveness evidence.
    pub session_display_name: Option<String>,
}

impl SessionSnapshot {
    pub fn new(
        family: AgentFamily,
        surface: Surface,
        native_session_id: String,
        cwd: Option<String>,
        source: String,
        source_activity_at: SystemTime,
    ) -> Self {
        Self {
            family,
            surface,
            native_session_id,
            cwd,
            attention_state: AttentionState::Unknown,
            attention_evidence: "no recognized attention evidence".to_string(),
            evidence_freshness: EvidenceFreshness::None,
            host_liveness: HostLiveness::Unknown,
            host_liveness_evidence: None,
            session_liveness: SessionLiveness::Unknown,
            session_liveness_evidence: None,
            runtime_binding_id: None,
            active_runtime_id: None,
            runtime_binding: None,
            source,
            last_attention_evidence_at: None,
            last_session_liveness_evidence_at: None,
            last_host_liveness_observed_at: None,
            last_source_activity_at: source_activity_at,
            last_observed_at: source_activity_at,
            session_display_name: None,
        }
    }

    pub fn set_attention(
        &mut self,
        attention_state: AttentionState,
        evidence: impl Into<String>,
        observed_at: Option<SystemTime>,
    ) {
        self.attention_state = attention_state;
        self.attention_evidence = evidence.into();
        self.last_attention_evidence_at = observed_at;
    }

    pub fn set_session_liveness(
        &mut self,
        session_liveness: SessionLiveness,
        evidence: impl Into<String>,
        observed_at: Option<SystemTime>,
    ) {
        self.session_liveness = session_liveness;
        self.session_liveness_evidence = Some(evidence.into());
        self.last_session_liveness_evidence_at = observed_at;
    }

    pub fn set_host_liveness(
        &mut self,
        host_liveness: HostLiveness,
        evidence: impl Into<String>,
        observed_at: SystemTime,
    ) {
        self.host_liveness = host_liveness;
        self.host_liveness_evidence = Some(evidence.into());
        self.last_host_liveness_observed_at = Some(observed_at);
    }

    pub fn apply_evidence_freshness(&mut self, now: SystemTime, stale_after: Duration) {
        self.last_observed_at = now;
        let Some(last_attention_evidence_at) = self.last_attention_evidence_at else {
            self.evidence_freshness = EvidenceFreshness::None;
            return;
        };
        let age = now
            .duration_since(last_attention_evidence_at)
            .unwrap_or(Duration::ZERO);
        self.evidence_freshness = if age > stale_after {
            EvidenceFreshness::Stale
        } else if age > Duration::from_secs(30) {
            EvidenceFreshness::Aging
        } else {
            EvidenceFreshness::Fresh
        };
    }

    pub fn bind_runtime(&mut self, binding: RuntimeBinding) -> bool {
        if binding.native_session_id != self.native_session_id {
            return false;
        }
        self.runtime_binding_id = Some(binding.runtime_binding_id.clone());
        if !binding.active_runtime_id.is_empty() {
            self.active_runtime_id = Some(binding.active_runtime_id.clone());
        }
        self.runtime_binding = Some(binding);
        true
    }

    /// Only an exact process/runtime monitor may call this after it observed
    /// this specific binding exit abnormally. A family-wide host process scan
    /// must use `set_host_liveness` instead.
    pub fn mark_lost_from_abnormal_bound_exit(&mut self, exit: &AbnormalRuntimeExit) -> bool {
        let Some(binding) = &self.runtime_binding else {
            return false;
        };
        if !binding.matches_abnormal_exit(exit) {
            return false;
        }
        if self.attention_state == AttentionState::ResultReady
            || self.session_liveness == SessionLiveness::Detached
        {
            return false;
        }

        self.set_host_liveness(
            HostLiveness::Dead,
            "exact runtime binding observed abnormal process exit",
            exit.observed_at,
        );
        self.set_session_liveness(
            SessionLiveness::Lost,
            "exact active runtime binding exited without a terminal event",
            Some(exit.observed_at),
        );
        true
    }
}

/// Collapse whitespace and reject path-like strings so a cwd cannot masquerade
/// as a session title. This is presentation-only.
pub fn presentation_session_name(raw: &str) -> Option<String> {
    let collapsed = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() || looks_like_filesystem_path(&collapsed) {
        return None;
    }

    let truncated: String = collapsed.chars().take(80).collect();
    let truncated = truncated.trim().to_string();
    if truncated.is_empty() {
        None
    } else {
        Some(truncated)
    }
}

fn looks_like_filesystem_path(value: &str) -> bool {
    value.contains(":\\")
        || value.contains(":/")
        || value.starts_with('\\')
        || value.starts_with('/')
}

pub fn unix_millis(time: SystemTime) -> u128 {
    time.duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis()
}

pub fn optional_unix_millis(time: Option<SystemTime>) -> Option<u128> {
    time.map(unix_millis)
}

pub fn system_time_from_unix_millis(millis: u128) -> Option<SystemTime> {
    UNIX_EPOCH.checked_add(Duration::from_millis(u64::try_from(millis).ok()?))
}

pub fn age_text(now: SystemTime, then: Option<SystemTime>) -> String {
    let Some(then) = then else {
        return "unavailable".to_string();
    };
    let age = now.duration_since(then).unwrap_or(Duration::ZERO);
    if age < Duration::from_secs(60) {
        format!("{:.1}s", age.as_secs_f64())
    } else if age < Duration::from_secs(60 * 60) {
        format!("{}m {}s", age.as_secs() / 60, age.as_secs() % 60)
    } else {
        format!("{}h {}m", age.as_secs() / 3600, (age.as_secs() % 3600) / 60)
    }
}

pub fn parse_rfc3339_utc(raw: &str) -> Option<SystemTime> {
    let date_time = raw.strip_suffix('Z')?;
    let (date, time) = date_time.split_once('T')?;
    let mut date_parts = date.split('-');
    let year = date_parts.next()?.parse::<i64>().ok()?;
    let month = date_parts.next()?.parse::<u32>().ok()?;
    let day = date_parts.next()?.parse::<u32>().ok()?;
    if date_parts.next().is_some() {
        return None;
    }

    let (clock, fraction) = time.split_once('.').unwrap_or((time, ""));
    let mut time_parts = clock.split(':');
    let hour = time_parts.next()?.parse::<u64>().ok()?;
    let minute = time_parts.next()?.parse::<u64>().ok()?;
    let second = time_parts.next()?.parse::<u64>().ok()?;
    if time_parts.next().is_some() || hour > 23 || minute > 59 || second > 59 {
        return None;
    }

    let days = days_since_unix_epoch(year, month, day)?;
    let seconds = days
        .checked_mul(86_400)?
        .checked_add((hour * 3_600 + minute * 60 + second) as i64)?;
    if seconds < 0 {
        return None;
    }

    let nanos = if fraction.is_empty() {
        0
    } else {
        let digits = fraction.chars().take(9).collect::<String>();
        if digits.is_empty() || !digits.chars().all(|character| character.is_ascii_digit()) {
            return None;
        }
        let scale = 9_u32.checked_sub(digits.len() as u32)?;
        digits.parse::<u32>().ok()?.checked_mul(10_u32.pow(scale))?
    };

    SystemTime::UNIX_EPOCH.checked_add(Duration::new(seconds as u64, nanos))
}

fn days_since_unix_epoch(year: i64, month: u32, day: u32) -> Option<i64> {
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }

    let adjusted_year = year - i64::from(month <= 2);
    let era = if adjusted_year >= 0 {
        adjusted_year / 400
    } else {
        (adjusted_year - 399) / 400
    };
    let year_of_era = adjusted_year - era * 400;
    let adjusted_month = if month > 2 {
        month as i64 - 3
    } else {
        month as i64 + 9
    };
    let day_of_year = (153 * adjusted_month + 2) / 5 + day as i64 - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era - 719_468)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(now: SystemTime) -> SessionSnapshot {
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Codex,
            Surface::Cli,
            "session-1".to_string(),
            None,
            "test".to_string(),
            now,
        );
        snapshot.set_attention(
            AttentionState::Working,
            "task_started",
            Some(now - Duration::from_secs(61)),
        );
        snapshot
    }

    #[test]
    fn stale_attention_evidence_does_not_overwrite_working() {
        let now = SystemTime::now();
        let mut snapshot = snapshot(now);

        snapshot.apply_evidence_freshness(now, Duration::from_secs(60));

        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Stale);
        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }

    #[test]
    fn pi_family_displays_as_canonical_pi() {
        assert_eq!(AgentFamily::Pi.to_string(), "Pi");
        assert_ne!(AgentFamily::Pi.to_string(), "Pi Agent");
        assert_ne!(AgentFamily::Pi.to_string(), "pi");
    }

    #[test]
    fn grok_family_displays_as_canonical_grok() {
        assert_eq!(AgentFamily::Grok.to_string(), "Grok");
    }

    #[test]
    fn core_freshness_uses_thirty_second_aging_boundary() {
        let now = SystemTime::now();
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Pi,
            Surface::Cli,
            "session-1".to_string(),
            None,
            "pi-rpc".to_string(),
            now,
        );
        snapshot.set_attention(
            AttentionState::Working,
            "Pi RPC agent_start received by Observer",
            Some(now - Duration::from_secs(30)),
        );
        snapshot.apply_evidence_freshness(now, Duration::from_secs(300));
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Fresh);

        snapshot.set_attention(
            AttentionState::Working,
            "Pi RPC agent_start received by Observer",
            Some(now - Duration::from_secs(30) - Duration::from_millis(1)),
        );
        snapshot.apply_evidence_freshness(now, Duration::from_secs(300));
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Aging);
    }

    #[test]
    fn core_freshness_respects_global_stale_after_override() {
        let now = SystemTime::now();
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Pi,
            Surface::Cli,
            "session-1".to_string(),
            None,
            "pi-rpc".to_string(),
            now,
        );
        snapshot.set_attention(
            AttentionState::Working,
            "Pi RPC agent_start received by Observer",
            Some(now - Duration::from_secs(33)),
        );
        snapshot.apply_evidence_freshness(now, Duration::from_secs(32));
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Stale);

        snapshot.apply_evidence_freshness(now, Duration::from_secs(300));
        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Aging);
    }

    #[test]
    fn absent_attention_timestamp_has_none_freshness() {
        let now = SystemTime::now();
        let mut snapshot = SessionSnapshot::new(
            AgentFamily::Claude,
            Surface::Cli,
            "session-1".to_string(),
            None,
            "test".to_string(),
            now,
        );

        snapshot.apply_evidence_freshness(now, Duration::from_secs(60));

        assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::None);
    }

    #[test]
    fn host_dead_without_runtime_binding_keeps_session_unknown() {
        let now = SystemTime::now();
        let mut snapshot = snapshot(now);

        snapshot.set_host_liveness(HostLiveness::Dead, "host process scan", now);

        assert_eq!(snapshot.host_liveness, HostLiveness::Dead);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn exact_active_runtime_exit_allows_lost() {
        let now = SystemTime::now();
        let process_started_at = now - Duration::from_secs(20);
        let binding = RuntimeBinding {
            runtime_binding_id: "binding-1".to_string(),
            native_session_id: "session-1".to_string(),
            active_runtime_id: "turn-1".to_string(),
            host_instance_id: "pid-10@start".to_string(),
            process_id: 10,
            process_started_at,
            active_observed_at: now - Duration::from_secs(1),
        };
        let mut snapshot = snapshot(now);
        assert!(snapshot.bind_runtime(binding.clone()));

        assert!(
            snapshot.mark_lost_from_abnormal_bound_exit(&AbnormalRuntimeExit {
                runtime_binding_id: binding.runtime_binding_id,
                native_session_id: binding.native_session_id,
                active_runtime_id: binding.active_runtime_id,
                host_instance_id: binding.host_instance_id,
                process_id: binding.process_id,
                process_started_at: binding.process_started_at,
                observed_at: now,
            })
        );

        assert_eq!(snapshot.host_liveness, HostLiveness::Dead);
        assert_eq!(snapshot.session_liveness, SessionLiveness::Lost);
        assert_eq!(snapshot.attention_state, AttentionState::Working);
    }

    #[test]
    fn runtime_binding_id_mismatch_does_not_mark_lost() {
        let now = SystemTime::now();
        let binding = test_binding(now, "binding-1", "turn-1", 10, now);
        let mut snapshot = snapshot(now);
        assert!(snapshot.bind_runtime(binding.clone()));

        let mut exit = binding.to_abnormal_exit(now).unwrap();
        exit.runtime_binding_id = "binding-other".to_string();

        assert!(!snapshot.mark_lost_from_abnormal_bound_exit(&exit));
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn same_pid_with_mismatched_creation_time_does_not_mark_lost() {
        let now = SystemTime::now();
        let started = now - Duration::from_secs(20);
        let binding = test_binding(now, "binding-1", "turn-1", 10, started);
        let mut snapshot = snapshot(now);
        assert!(snapshot.bind_runtime(binding.clone()));

        let mut exit = binding.to_abnormal_exit(now).unwrap();
        exit.process_started_at = started + Duration::from_secs(5);

        assert!(!snapshot.mark_lost_from_abnormal_bound_exit(&exit));
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }

    #[test]
    fn missing_active_runtime_does_not_mark_lost() {
        let now = SystemTime::now();
        let binding = test_binding(now, "binding-1", "", 10, now - Duration::from_secs(20));
        let mut snapshot = snapshot(now);
        assert!(snapshot.bind_runtime(binding.clone()));
        assert!(!binding.is_exact_active());
        assert!(binding.to_abnormal_exit(now).is_none());
        assert_eq!(snapshot.session_liveness, SessionLiveness::Unknown);
    }

    fn test_binding(
        now: SystemTime,
        runtime_binding_id: &str,
        active_runtime_id: &str,
        process_id: u32,
        process_started_at: SystemTime,
    ) -> RuntimeBinding {
        RuntimeBinding {
            runtime_binding_id: runtime_binding_id.to_string(),
            native_session_id: "session-1".to_string(),
            active_runtime_id: active_runtime_id.to_string(),
            host_instance_id: format!("pid-{process_id}@start"),
            process_id,
            process_started_at,
            active_observed_at: now - Duration::from_secs(1),
        }
    }

    #[test]
    fn presentation_session_name_rejects_paths_and_empty_values() {
        assert_eq!(
            presentation_session_name("  Fix quota reset jitter  "),
            Some("Fix quota reset jitter".to_string())
        );
        assert_eq!(presentation_session_name("D:\\synthetic-workspace"), None);
        assert_eq!(presentation_session_name("   \n\t  "), None);
        assert_eq!(presentation_session_name("/home/user/project"), None);
    }

    #[test]
    fn stale_evidence_is_independent_of_alive_or_unknown_host() {
        let now = SystemTime::now();
        for host_liveness in [HostLiveness::Alive, HostLiveness::Unknown] {
            let mut snapshot = snapshot(now);
            snapshot.set_host_liveness(host_liveness, "test host state", now);
            snapshot.apply_evidence_freshness(now, Duration::from_secs(60));

            assert_eq!(snapshot.evidence_freshness, EvidenceFreshness::Stale);
            assert_eq!(snapshot.attention_state, AttentionState::Working);
            assert_eq!(snapshot.host_liveness, host_liveness);
        }
    }
}
