use anyhow::{anyhow, Result};
use shared::EventV1;
use std::{fmt, str::FromStr};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeverityLevel {
    Low,
    Medium,
    High,
    Critical,
}

impl SeverityLevel {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Critical => "critical",
        }
    }

    pub const fn rank(self) -> u8 {
        match self {
            Self::Low => 1,
            Self::Medium => 2,
            Self::High => 3,
            Self::Critical => 4,
        }
    }

    pub const fn max(self, other: Self) -> Self {
        if self.rank() >= other.rank() {
            self
        } else {
            other
        }
    }
}

impl fmt::Display for SeverityLevel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl FromStr for SeverityLevel {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "low" => Ok(Self::Low),
            "medium" => Ok(Self::Medium),
            "high" => Ok(Self::High),
            "critical" => Ok(Self::Critical),
            other => Err(anyhow!("invalid severity level: {other}")),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SeverityConfig {
    pub repeat_window_seconds: i64,
    pub medium_threshold: i64,
    pub high_threshold: i64,
    pub critical_threshold: i64,
    pub decoy_level: SeverityLevel,
    pub credential_decoy_level: SeverityLevel,
}

impl SeverityConfig {
    pub fn validate(&self) -> Result<()> {
        if self.repeat_window_seconds <= 0 {
            return Err(anyhow!("repeat_window_seconds must be > 0"));
        }

        if self.medium_threshold <= 1 {
            return Err(anyhow!("medium_threshold must be >= 2"));
        }

        if self.high_threshold < self.medium_threshold {
            return Err(anyhow!("high_threshold must be >= medium_threshold"));
        }

        if self.critical_threshold < self.high_threshold {
            return Err(anyhow!("critical_threshold must be >= high_threshold"));
        }

        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeverityDecision {
    pub level: SeverityLevel,
    pub reason: String,
    pub attempt_count: i32,
}

fn repeat_severity(cfg: &SeverityConfig, attempt_count: i64) -> (SeverityLevel, &'static str) {
    if attempt_count >= cfg.critical_threshold {
        (SeverityLevel::Critical, "repeat_threshold_critical")
    } else if attempt_count >= cfg.high_threshold {
        (SeverityLevel::High, "repeat_threshold_high")
    } else if attempt_count >= cfg.medium_threshold {
        (SeverityLevel::Medium, "repeat_threshold_medium")
    } else {
        (SeverityLevel::Low, "default_low")
    }
}

fn decoy_override(cfg: &SeverityConfig, event: &EventV1) -> Option<(SeverityLevel, &'static str)> {
    if event.evidence.decoy_hit != Some(true) {
        return None;
    }

    let is_credential_decoy = event
        .evidence
        .decoy_kind
        .as_deref()
        .map(|v| v.eq_ignore_ascii_case("credential"))
        .unwrap_or(false);

    if is_credential_decoy {
        Some((cfg.credential_decoy_level, "decoy_credential_hit"))
    } else {
        Some((cfg.decoy_level, "decoy_hit"))
    }
}

pub fn decide_severity(
    cfg: &SeverityConfig,
    event: &EventV1,
    prior_attempts: i64,
) -> SeverityDecision {
    let attempt_count_i64 = prior_attempts.saturating_add(1);
    let attempt_count = i32::try_from(attempt_count_i64).unwrap_or(i32::MAX);

    let (repeat_level, repeat_reason) = repeat_severity(cfg, attempt_count_i64);
    let mut final_level = repeat_level;

    let mut reasons = Vec::new();
    if repeat_reason != "default_low" {
        reasons.push(repeat_reason.to_string());
    }

    if let Some((decoy_level, decoy_reason)) = decoy_override(cfg, event) {
        final_level = final_level.max(decoy_level);
        reasons.push(decoy_reason.to_string());
    }

    let reason = if reasons.is_empty() {
        "default_low".to_string()
    } else {
        reasons.join("+")
    };

    SeverityDecision {
        level: final_level,
        reason,
        attempt_count,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shared::{EventV1, Evidence, ServiceKind};
    use uuid::Uuid;

    fn base_http_event() -> EventV1 {
        EventV1::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            ServiceKind::Http,
            "203.0.113.55",
            45678,
            "2026-03-20T00:00:00Z",
            Evidence {
                username: None,
                ssh_auth_method: None,
                http_user_agent: Some("ua".to_string()),
                http_method: Some("GET".to_string()),
                http_path: Some("/login".to_string()),
                decoy_hit: None,
                decoy_kind: None,
            },
        )
    }

    fn base_ssh_decoy_event() -> EventV1 {
        EventV1::new(
            Uuid::new_v4(),
            Uuid::new_v4(),
            ServiceKind::Ssh,
            "203.0.113.99",
            54321,
            "2026-03-20T00:00:00Z",
            Evidence {
                username: Some("decoy-admin".to_string()),
                ssh_auth_method: Some("password".to_string()),
                http_user_agent: None,
                http_method: None,
                http_path: None,
                decoy_hit: Some(true),
                decoy_kind: Some("credential".to_string()),
            },
        )
    }

    fn default_cfg() -> SeverityConfig {
        SeverityConfig {
            repeat_window_seconds: 600,
            medium_threshold: 3,
            high_threshold: 5,
            critical_threshold: 10,
            decoy_level: SeverityLevel::High,
            credential_decoy_level: SeverityLevel::Critical,
        }
    }

    #[test]
    fn repeated_attempts_escalate() {
        let cfg = default_cfg();
        let ev = base_http_event();

        assert_eq!(decide_severity(&cfg, &ev, 0).level, SeverityLevel::Low);
        assert_eq!(decide_severity(&cfg, &ev, 2).level, SeverityLevel::Medium);
        assert_eq!(decide_severity(&cfg, &ev, 4).level, SeverityLevel::High);
        assert_eq!(decide_severity(&cfg, &ev, 9).level, SeverityLevel::Critical);
    }

    #[test]
    fn credential_decoy_is_critical() {
        let cfg = default_cfg();
        let ev = base_ssh_decoy_event();

        let decision = decide_severity(&cfg, &ev, 0);
        assert_eq!(decision.level, SeverityLevel::Critical);
        assert!(decision.reason.contains("decoy_credential_hit"));
    }
}
