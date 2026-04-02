use anyhow::{anyhow, Result};
use serde::Deserialize;
use std::path::Path;
use uuid::Uuid;

#[derive(Debug, Clone, Deserialize)]
pub struct SensorConfig {
    pub sensor: SensorSection,
    pub control_plane: ControlPlaneSection,
    pub runtime: RuntimeSection,
    pub logging: LoggingSection,

    #[serde(default)]
    pub honeypots: HoneypotsSection,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SensorSection {
    pub tenant_id: Uuid,
    pub sensor_id: Uuid,
    pub sensor_token: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ControlPlaneSection {
    pub base_url: String,

    #[serde(default = "default_heartbeat_path")]
    pub heartbeat_path: String,

    #[serde(default = "default_ingest_path")]
    pub ingest_path: String,

    #[serde(default = "default_request_timeout_seconds")]
    pub request_timeout_seconds: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RuntimeSection {
    #[serde(default = "default_heartbeat_interval_seconds")]
    pub heartbeat_interval_seconds: u64,

    #[serde(default = "default_max_queue")]
    pub max_queue: usize,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LoggingSection {
    #[serde(default = "default_log_level")]
    pub level: String,

    #[serde(default = "default_log_format")]
    pub format: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HoneypotsSection {
    /// T12
    pub ssh_listen_addr: Option<String>,

    /// T12
    #[serde(default = "default_ssh_banner")]
    pub ssh_banner: String,

    /// T13
    pub http_listen_addr: Option<String>,

    /// T13
    pub https_listen_addr: Option<String>,

    /// T13
    #[serde(default = "default_http_trap_paths")]
    pub http_trap_paths: Vec<String>,
}

impl Default for HoneypotsSection {
    fn default() -> Self {
        Self {
            ssh_listen_addr: None,
            ssh_banner: default_ssh_banner(),
            http_listen_addr: None,
            https_listen_addr: None,
            http_trap_paths: default_http_trap_paths(),
        }
    }
}

fn default_heartbeat_path() -> String {
    "/sensors/{sensor_id}/heartbeat".to_string()
}

fn default_ingest_path() -> String {
    "/events/ingest".to_string()
}

const fn default_request_timeout_seconds() -> u64 {
    10
}

const fn default_heartbeat_interval_seconds() -> u64 {
    30
}

const fn default_max_queue() -> usize {
    10_000
}

fn default_log_level() -> String {
    "info".to_string()
}

fn default_log_format() -> String {
    "pretty".to_string()
}

fn default_ssh_banner() -> String {
    "OpenSSH_8.9p1 Ubuntu-3ubuntu0.10".to_string()
}

fn default_http_trap_paths() -> Vec<String> {
    vec![
        "/login".to_string(),
        "/admin".to_string(),
        "/wp-login.php".to_string(),
    ]
}

pub fn load_config(path: &Path) -> Result<SensorConfig> {
    let cfg = config::Config::builder()
        .add_source(config::File::from(path))
        .add_source(
            config::Environment::with_prefix("DM")
                .separator("__")
                .try_parsing(true),
        )
        .build()?
        .try_deserialize::<SensorConfig>()?;

    validate(&cfg)?;
    Ok(cfg)
}

fn validate(cfg: &SensorConfig) -> Result<()> {
    if cfg.sensor.sensor_token.trim().is_empty() {
        return Err(anyhow!("sensor.sensor_token is required"));
    }

    if !(cfg.control_plane.base_url.starts_with("https://")
        || cfg.control_plane.base_url.starts_with("http://"))
    {
        return Err(anyhow!(
            "control_plane.base_url must start with https:// or http://"
        ));
    }

    if !cfg.control_plane.ingest_path.trim().starts_with('/') {
        return Err(anyhow!("control_plane.ingest_path must start with '/'"));
    }

    if cfg.honeypots.ssh_banner.trim().is_empty() {
        return Err(anyhow!("honeypots.ssh_banner cannot be empty"));
    }

    if cfg.honeypots.http_trap_paths.is_empty() {
        return Err(anyhow!("honeypots.http_trap_paths cannot be empty"));
    }

    for path in &cfg.honeypots.http_trap_paths {
        let trimmed = path.trim();
        if trimmed.is_empty() {
            return Err(anyhow!(
                "honeypots.http_trap_paths cannot contain empty paths"
            ));
        }
    }

    Ok(())
}
