use crate::event_reporter::{now_rfc3339, EventPublisher};
use anyhow::{Context, Result};
use async_trait::async_trait;
use russh::server::{Auth, Server, Session};
use russh::{server, Channel, MethodSet};
use russh_keys::key::KeyPair;
use shared::{EventV1, Evidence, ServiceKind};
use std::{net::SocketAddr, sync::Arc, time::Duration};
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct SshHoneypotConfig {
    pub tenant_id: Uuid,
    pub sensor_id: Uuid,
    pub listen_addr: String,
    pub banner: String,
    pub publisher: EventPublisher,
}

#[derive(Debug, Clone)]
struct SshServer {
    cfg: Arc<SshHoneypotConfig>,
    peer_addr: Option<SocketAddr>,
}

impl SshServer {
    fn new(cfg: SshHoneypotConfig) -> Self {
        Self {
            cfg: Arc::new(cfg),
            peer_addr: None,
        }
    }

    fn peer_ip(&self) -> String {
        self.peer_addr
            .map(|a| a.ip().to_string())
            .unwrap_or_else(|| "unknown".to_string())
    }

    fn peer_port(&self) -> u16 {
        self.peer_addr.map(|a| a.port()).unwrap_or(0)
    }

    fn reject_auth(&self) -> Auth {
        Auth::Reject {
            proceed_with_methods: Some(MethodSet::PASSWORD | MethodSet::PUBLICKEY),
        }
    }

    fn emit_auth_event(&self, username: &str, method: &str) {
        let event = EventV1::new(
            self.cfg.tenant_id,
            self.cfg.sensor_id,
            ServiceKind::Ssh,
            self.peer_ip(),
            self.peer_port(),
            now_rfc3339(),
            Evidence {
                username: Some(username.to_string()),
                ssh_auth_method: Some(method.to_string()),
                http_user_agent: None,
                http_method: None,
                http_path: None,
                decoy_hit: None,
                decoy_kind: None,
            },
        );

        self.cfg.publisher.publish(event);
    }

    fn log_attempt(&self, username: &str, method: &str) {
        info!(
            service = "ssh",
            event_kind = "ssh_auth_attempt",
            tenant_id = %self.cfg.tenant_id,
            sensor_id = %self.cfg.sensor_id,
            src_ip = %self.peer_ip(),
            src_port = self.peer_port(),
            username = username,
            ssh_auth_method = method,
            banner = %self.cfg.banner,
            "ssh auth attempt captured"
        );

        self.emit_auth_event(username, method);
    }
}

impl server::Server for SshServer {
    type Handler = Self;

    fn new_client(&mut self, peer_addr: Option<SocketAddr>) -> Self {
        let mut next = self.clone();
        next.peer_addr = peer_addr;
        next
    }
}

#[async_trait]
impl server::Handler for SshServer {
    type Error = anyhow::Error;

    async fn auth_none(&mut self, user: &str) -> Result<Auth, Self::Error> {
        self.log_attempt(user, "none");
        Ok(self.reject_auth())
    }

    async fn auth_password(&mut self, user: &str, _password: &str) -> Result<Auth, Self::Error> {
        self.log_attempt(user, "password");
        Ok(self.reject_auth())
    }

    async fn auth_publickey_offered(
        &mut self,
        user: &str,
        _public_key: &russh_keys::key::PublicKey,
    ) -> Result<Auth, Self::Error> {
        self.log_attempt(user, "publickey_offered");
        Ok(self.reject_auth())
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<russh::server::Msg>,
        _session: &mut Session,
    ) -> Result<bool, Self::Error> {
        warn!(
            service = "ssh",
            tenant_id = %self.cfg.tenant_id,
            sensor_id = %self.cfg.sensor_id,
            src_ip = %self.peer_ip(),
            src_port = self.peer_port(),
            "ssh session request denied"
        );
        Ok(false)
    }
}

pub async fn run_ssh_honeypot(cfg: SshHoneypotConfig) -> Result<()> {
    let mut server_cfg = russh::server::Config {
        inactivity_timeout: Some(Duration::from_secs(30)),
        auth_rejection_time: Duration::from_millis(200),
        ..Default::default()
    };

    server_cfg.keys.push(
        KeyPair::generate_ed25519().context("failed to generate ephemeral ed25519 host key")?,
    );

    let server_cfg = Arc::new(server_cfg);

    let listen_addr: SocketAddr = cfg
        .listen_addr
        .parse()
        .with_context(|| format!("invalid ssh listen_addr: {}", cfg.listen_addr))?;

    info!(
        service = "ssh",
        tenant_id = %cfg.tenant_id,
        sensor_id = %cfg.sensor_id,
        listen_addr = %listen_addr,
        banner = %cfg.banner,
        "ssh honeypot listening"
    );

    let mut server = SshServer::new(cfg.clone());

    server
        .run_on_address(server_cfg, listen_addr)
        .await
        .with_context(|| format!("ssh honeypot failed on {}", listen_addr))?;

    Ok(())
}
