use serde::{Deserialize, Serialize};
use std::fmt;
use uuid::Uuid;

pub const EVENT_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceKind {
    Ssh,
    Http,
    Https,
}

impl ServiceKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Ssh => "ssh",
            Self::Http => "http",
            Self::Https => "https",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EventContractError {
    UnsupportedSchemaVersion { found: u32 },
    EmptySrcIp,
    InvalidSrcPort,
    EmptyTimestampRfc3339,
    MissingSshUsername,
    MissingSshAuthMethod,
    MissingHttpMethod,
    MissingHttpPath,
}

impl fmt::Display for EventContractError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedSchemaVersion { found } => {
                write!(
                    f,
                    "unsupported schema_version: expected {}, got {}",
                    EVENT_SCHEMA_VERSION, found
                )
            }
            Self::EmptySrcIp => write!(f, "src_ip cannot be empty"),
            Self::InvalidSrcPort => write!(f, "src_port must be greater than zero"),
            Self::EmptyTimestampRfc3339 => write!(f, "timestamp_rfc3339 cannot be empty"),
            Self::MissingSshUsername => {
                write!(f, "ssh evidence requires a non-empty username")
            }
            Self::MissingSshAuthMethod => {
                write!(f, "ssh evidence requires a non-empty ssh_auth_method")
            }
            Self::MissingHttpMethod => {
                write!(f, "http/https evidence requires a non-empty http_method")
            }
            Self::MissingHttpPath => {
                write!(f, "http/https evidence requires a non-empty http_path")
            }
        }
    }
}

impl std::error::Error for EventContractError {}

fn is_blank(s: &str) -> bool {
    s.trim().is_empty()
}

fn option_is_blank(v: Option<&str>) -> bool {
    match v {
        Some(s) => is_blank(s),
        None => true,
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Evidence {
    pub username: Option<String>,
    pub ssh_auth_method: Option<String>,
    pub http_user_agent: Option<String>,
    pub http_method: Option<String>,
    pub http_path: Option<String>,

    // T18/T14/T15
    pub decoy_hit: Option<bool>,
    pub decoy_kind: Option<String>,
}

impl Evidence {
    pub fn validate_for(&self, service: ServiceKind) -> Result<(), EventContractError> {
        match service {
            ServiceKind::Ssh => {
                if option_is_blank(self.username.as_deref()) {
                    return Err(EventContractError::MissingSshUsername);
                }

                if option_is_blank(self.ssh_auth_method.as_deref()) {
                    return Err(EventContractError::MissingSshAuthMethod);
                }
            }
            ServiceKind::Http | ServiceKind::Https => {
                if option_is_blank(self.http_method.as_deref()) {
                    return Err(EventContractError::MissingHttpMethod);
                }

                if option_is_blank(self.http_path.as_deref()) {
                    return Err(EventContractError::MissingHttpPath);
                }
            }
        }

        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EventV1 {
    pub schema_version: u32,
    pub event_id: Uuid,
    pub tenant_id: Uuid,
    pub sensor_id: Uuid,
    pub service: ServiceKind,
    pub src_ip: String,
    pub src_port: u16,
    pub timestamp_rfc3339: String,
    pub evidence: Evidence,
}

impl EventV1 {
    pub fn new(
        tenant_id: Uuid,
        sensor_id: Uuid,
        service: ServiceKind,
        src_ip: impl Into<String>,
        src_port: u16,
        timestamp_rfc3339: impl Into<String>,
        evidence: Evidence,
    ) -> Self {
        Self {
            schema_version: EVENT_SCHEMA_VERSION,
            event_id: Uuid::new_v4(),
            tenant_id,
            sensor_id,
            service,
            src_ip: src_ip.into(),
            src_port,
            timestamp_rfc3339: timestamp_rfc3339.into(),
            evidence,
        }
    }

    pub fn validate_contract(&self) -> Result<(), EventContractError> {
        if self.schema_version != EVENT_SCHEMA_VERSION {
            return Err(EventContractError::UnsupportedSchemaVersion {
                found: self.schema_version,
            });
        }

        if is_blank(&self.src_ip) {
            return Err(EventContractError::EmptySrcIp);
        }

        if self.src_port == 0 {
            return Err(EventContractError::InvalidSrcPort);
        }

        if is_blank(&self.timestamp_rfc3339) {
            return Err(EventContractError::EmptyTimestampRfc3339);
        }

        self.evidence.validate_for(self.service)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn event_v1_json_roundtrip_ok() {
        let tenant_id = Uuid::new_v4();
        let sensor_id = Uuid::new_v4();

        let ev = EventV1::new(
            tenant_id,
            sensor_id,
            ServiceKind::Ssh,
            "203.0.113.10",
            54321,
            "2025-12-17T00:00:00Z",
            Evidence {
                username: Some("root".to_string()),
                ssh_auth_method: Some("password".to_string()),
                http_user_agent: None,
                http_method: None,
                http_path: None,
                decoy_hit: None,
                decoy_kind: None,
            },
        );

        let s = serde_json::to_string(&ev).expect("serialize");
        let back: EventV1 = serde_json::from_str(&s).expect("deserialize");

        assert_eq!(back.schema_version, EVENT_SCHEMA_VERSION);
        assert_eq!(back.tenant_id, tenant_id);
        assert_eq!(back.sensor_id, sensor_id);
        assert_eq!(back.service, ServiceKind::Ssh);
        assert_eq!(back.src_port, 54321);
        assert_eq!(back.evidence.username.as_deref(), Some("root"));
        assert_eq!(back.evidence.ssh_auth_method.as_deref(), Some("password"));
    }

    #[test]
    fn missing_required_field_is_rejected_by_serde() {
        let value = json!({
            "schema_version": 1,
            "event_id": Uuid::new_v4(),
            "tenant_id": Uuid::new_v4(),
            "sensor_id": Uuid::new_v4(),
            "service": "http",
            "src_ip": "203.0.113.25",
            "src_port": 8080,
            "timestamp_rfc3339": "2026-03-20T00:00:00Z"
        });

        let parsed = serde_json::from_value::<EventV1>(value);
        assert!(parsed.is_err());
    }

    #[test]
    fn unknown_fields_are_rejected_by_serde() {
        let value = json!({
            "schema_version": 1,
            "event_id": Uuid::new_v4(),
            "tenant_id": Uuid::new_v4(),
            "sensor_id": Uuid::new_v4(),
            "service": "http",
            "src_ip": "203.0.113.25",
            "src_port": 8080,
            "timestamp_rfc3339": "2026-03-20T00:00:00Z",
            "evidence": {
                "username": null,
                "ssh_auth_method": null,
                "http_user_agent": "ua",
                "http_method": "GET",
                "http_path": "/login",
                "decoy_hit": null,
                "decoy_kind": null
            },
            "unexpected_field": true
        });

        let parsed = serde_json::from_value::<EventV1>(value);
        assert!(parsed.is_err());
    }

    #[test]
    fn unsupported_schema_version_is_rejected() {
        let ev = EventV1 {
            schema_version: 2,
            event_id: Uuid::new_v4(),
            tenant_id: Uuid::new_v4(),
            sensor_id: Uuid::new_v4(),
            service: ServiceKind::Http,
            src_ip: "203.0.113.25".to_string(),
            src_port: 8080,
            timestamp_rfc3339: "2026-03-20T00:00:00Z".to_string(),
            evidence: Evidence {
                username: None,
                ssh_auth_method: None,
                http_user_agent: Some("ua".to_string()),
                http_method: Some("GET".to_string()),
                http_path: Some("/login".to_string()),
                decoy_hit: None,
                decoy_kind: None,
            },
        };

        let err = ev
            .validate_contract()
            .expect_err("schema_version should fail");
        assert_eq!(
            err,
            EventContractError::UnsupportedSchemaVersion { found: 2 }
        );
    }

    #[test]
    fn ssh_event_requires_username_and_auth_method() {
        let ev = EventV1 {
            schema_version: 1,
            event_id: Uuid::new_v4(),
            tenant_id: Uuid::new_v4(),
            sensor_id: Uuid::new_v4(),
            service: ServiceKind::Ssh,
            src_ip: "203.0.113.10".to_string(),
            src_port: 2222,
            timestamp_rfc3339: "2026-03-20T00:00:00Z".to_string(),
            evidence: Evidence {
                username: None,
                ssh_auth_method: Some("password".to_string()),
                http_user_agent: None,
                http_method: None,
                http_path: None,
                decoy_hit: None,
                decoy_kind: None,
            },
        };

        let err = ev
            .validate_contract()
            .expect_err("ssh contract should fail");
        assert_eq!(err, EventContractError::MissingSshUsername);
    }

    #[test]
    fn http_event_requires_method_and_path() {
        let ev = EventV1 {
            schema_version: 1,
            event_id: Uuid::new_v4(),
            tenant_id: Uuid::new_v4(),
            sensor_id: Uuid::new_v4(),
            service: ServiceKind::Http,
            src_ip: "203.0.113.25".to_string(),
            src_port: 8080,
            timestamp_rfc3339: "2026-03-20T00:00:00Z".to_string(),
            evidence: Evidence {
                username: None,
                ssh_auth_method: None,
                http_user_agent: Some("ua".to_string()),
                http_method: Some("GET".to_string()),
                http_path: None,
                decoy_hit: None,
                decoy_kind: None,
            },
        };

        let err = ev
            .validate_contract()
            .expect_err("http contract should fail");
        assert_eq!(err, EventContractError::MissingHttpPath);
    }
}
