use anyhow::{anyhow, Context, Result};
use clap::Parser;
use reqwest::{header::AUTHORIZATION, Client};
use serde::Serialize;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};
use tokio::time::MissedTickBehavior;
use tracing::{info, warn, Instrument};
use tracing_subscriber::EnvFilter;

mod config;
mod event_reporter;
mod http_honeypot;
mod ssh_honeypot;

use config::load_config;
use event_reporter::{start_event_reporter, EventReporterConfig};
use http_honeypot::{run_http_honeypots, HttpHoneypotConfig};
use ssh_honeypot::{run_ssh_honeypot, SshHoneypotConfig};

#[derive(Debug, Parser)]
#[command(
    name = "sensor_agent",
    version,
    about = "Deception Mesh Sensor Agent (T29 quickstart-ready)"
)]
struct Args {
    #[arg(long)]
    config: PathBuf,

    #[arg(long)]
    log: Option<String>,
}

#[derive(Debug, Serialize)]
struct HeartbeatPayload {
    agent_version: String,
    rtt_ms: Option<i32>,
}

fn init_tracing(level: &str, format: &str) {
    let builder = tracing_subscriber::fmt().with_env_filter(EnvFilter::new(level));

    if format.eq_ignore_ascii_case("json") {
        builder.json().init();
    } else {
        builder.init();
    }
}

fn join_base_and_path(base_url: &str, path: &str) -> String {
    let base = base_url.trim_end_matches('/');
    let path = path.strip_prefix('/').unwrap_or(path);
    format!("{base}/{path}")
}

fn build_http_client(timeout_seconds: u64) -> Result<Client> {
    let client = Client::builder()
        .timeout(Duration::from_secs(timeout_seconds.max(1)))
        .build()
        .context("failed to build reqwest client")?;

    Ok(client)
}

async fn send_heartbeat(client: &Client, heartbeat_url: &str, sensor_token: &str) -> Result<i32> {
    let started = Instant::now();

    let payload = HeartbeatPayload {
        agent_version: env!("CARGO_PKG_VERSION").to_string(),
        rtt_ms: None,
    };

    let response = client
        .post(heartbeat_url)
        .header(AUTHORIZATION, format!("Bearer {sensor_token}"))
        .json(&payload)
        .send()
        .await
        .with_context(|| format!("heartbeat request failed to {heartbeat_url}"))?;

    let elapsed_ms = started.elapsed().as_millis().min(i32::MAX as u128) as i32;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(anyhow!(
            "heartbeat rejected by control plane: status={} body={}",
            status,
            body
        ));
    }

    Ok(elapsed_ms)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let cfg = load_config(&args.config)?;

    let log_level = args.log.as_deref().unwrap_or(&cfg.logging.level);
    init_tracing(log_level, &cfg.logging.format);

    let root_span = tracing::info_span!(
        "sensor_agent",
        tenant_id = %cfg.sensor.tenant_id,
        sensor_id = %cfg.sensor.sensor_id
    );
    let _guard = root_span.enter();

    let heartbeat_url = join_base_and_path(
        &cfg.control_plane.base_url,
        &cfg.control_plane
            .heartbeat_path
            .replace("{sensor_id}", &cfg.sensor.sensor_id.to_string()),
    );

    let ingest_url =
        join_base_and_path(&cfg.control_plane.base_url, &cfg.control_plane.ingest_path);

    let event_publisher = start_event_reporter(EventReporterConfig {
        ingest_url: ingest_url.clone(),
        sensor_token: cfg.sensor.sensor_token.clone(),
        request_timeout_seconds: cfg.control_plane.request_timeout_seconds.max(1),
        max_queue: cfg.runtime.max_queue.max(1),
    })?;

    let heartbeat_client = build_http_client(cfg.control_plane.request_timeout_seconds.max(1))?;

    info!(
        service = "bootstrap",
        config_path = %args.config.display(),
        control_plane = %cfg.control_plane.base_url,
        heartbeat_url = %heartbeat_url,
        ingest_url = %ingest_url,
        request_timeout_s = cfg.control_plane.request_timeout_seconds.max(1),
        heartbeat_interval_s = cfg.runtime.heartbeat_interval_seconds.max(5),
        max_queue = cfg.runtime.max_queue.max(1),
        ssh_listen_addr = ?cfg.honeypots.ssh_listen_addr,
        ssh_banner = %cfg.honeypots.ssh_banner,
        http_listen_addr = ?cfg.honeypots.http_listen_addr,
        https_listen_addr = ?cfg.honeypots.https_listen_addr,
        http_trap_paths = ?cfg.honeypots.http_trap_paths,
        "sensor agent starting"
    );

    if cfg.control_plane.base_url.starts_with("http://") {
        warn!(
            service = "bootstrap",
            base_url = %cfg.control_plane.base_url,
            "control_plane is using http:// (allowed only for dev/local quickstart)"
        );
    }

    if let Some(ssh_listen_addr) = cfg
        .honeypots
        .ssh_listen_addr
        .clone()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
    {
        let ssh_cfg = SshHoneypotConfig {
            tenant_id: cfg.sensor.tenant_id,
            sensor_id: cfg.sensor.sensor_id,
            listen_addr: ssh_listen_addr.clone(),
            banner: cfg.honeypots.ssh_banner.clone(),
            publisher: event_publisher.clone(),
        };

        let ssh_span = tracing::info_span!(
            "ssh_honeypot_task",
            tenant_id = %cfg.sensor.tenant_id,
            sensor_id = %cfg.sensor.sensor_id,
            listen_addr = %ssh_listen_addr
        );

        tokio::spawn(
            async move {
                if let Err(e) = run_ssh_honeypot(ssh_cfg).await {
                    warn!(error = %e, "ssh honeypot exited with error");
                }
            }
            .instrument(ssh_span),
        );
    }

    let http_listen_addr = cfg
        .honeypots
        .http_listen_addr
        .clone()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let https_listen_addr = cfg
        .honeypots
        .https_listen_addr
        .clone()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    if http_listen_addr.is_some() || https_listen_addr.is_some() {
        let http_cfg = HttpHoneypotConfig {
            tenant_id: cfg.sensor.tenant_id,
            sensor_id: cfg.sensor.sensor_id,
            http_listen_addr,
            https_listen_addr,
            trap_paths: cfg.honeypots.http_trap_paths.clone(),
            publisher: event_publisher.clone(),
        };

        let http_span = tracing::info_span!(
            "http_honeypot_task",
            tenant_id = %cfg.sensor.tenant_id,
            sensor_id = %cfg.sensor.sensor_id
        );

        tokio::spawn(
            async move {
                if let Err(e) = run_http_honeypots(http_cfg).await {
                    warn!(error = %e, "http/https honeypot exited with error");
                }
            }
            .instrument(http_span),
        );
    }

    let mut interval = tokio::time::interval(Duration::from_secs(
        cfg.runtime.heartbeat_interval_seconds.max(5),
    ));
    interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                info!(service = "shutdown", "ctrl-c received, stopping");
                break;
            }
            _ = interval.tick() => {
                let hb_span = tracing::info_span!(
                    "heartbeat_tick",
                    tenant_id = %cfg.sensor.tenant_id,
                    sensor_id = %cfg.sensor.sensor_id,
                    service = "heartbeat"
                );

                match send_heartbeat(
                    &heartbeat_client,
                    &heartbeat_url,
                    &cfg.sensor.sensor_token,
                )
                .instrument(hb_span)
                .await
                {
                    Ok(rtt_ms) => {
                        info!(
                            service = "heartbeat",
                            heartbeat_url = %heartbeat_url,
                            agent_version = env!("CARGO_PKG_VERSION"),
                            rtt_ms = rtt_ms,
                            "heartbeat delivered"
                        );
                    }
                    Err(e) => {
                        warn!(
                            service = "heartbeat",
                            heartbeat_url = %heartbeat_url,
                            error = %e,
                            "heartbeat failed"
                        );
                    }
                }
            }
        }
    }

    info!(service = "shutdown", "sensor agent exited cleanly");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::join_base_and_path;

    #[test]
    fn joins_url_without_double_slash() {
        assert_eq!(
            join_base_and_path("http://localhost:8080/", "/health"),
            "http://localhost:8080/health"
        );
    }
}
