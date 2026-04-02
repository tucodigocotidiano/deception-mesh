use anyhow::Result;
use chrono::{SecondsFormat, Utc};
use reqwest::{header::AUTHORIZATION, Client};
use shared::EventV1;
use std::time::Duration;
use tokio::sync::{mpsc, mpsc::error::TrySendError};
use tracing::{info, warn};

#[derive(Debug, Clone)]
pub struct EventReporterConfig {
    pub ingest_url: String,
    pub sensor_token: String,
    pub request_timeout_seconds: u64,
    pub max_queue: usize,
}

#[derive(Debug, Clone)]
pub struct EventPublisher {
    tx: mpsc::Sender<EventV1>,
}

pub fn now_rfc3339() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

pub fn start_event_reporter(cfg: EventReporterConfig) -> Result<EventPublisher> {
    let (tx, mut rx) = mpsc::channel::<EventV1>(cfg.max_queue.max(1));

    let client = Client::builder()
        .timeout(Duration::from_secs(cfg.request_timeout_seconds.max(1)))
        .build()?;

    let ingest_url = cfg.ingest_url.clone();
    let sensor_token = cfg.sensor_token.clone();

    tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            let event_id = event.event_id;

            match client
                .post(&ingest_url)
                .header(AUTHORIZATION, format!("Bearer {sensor_token}"))
                .json(&event)
                .send()
                .await
            {
                Ok(resp) if resp.status().is_success() => {
                    info!(
                        event_id = %event_id,
                        ingest_url = %ingest_url,
                        status = %resp.status(),
                        "event reported to control plane"
                    );
                }
                Ok(resp) => {
                    let status = resp.status();
                    let body = resp.text().await.unwrap_or_else(|_| "".to_string());

                    warn!(
                        event_id = %event_id,
                        ingest_url = %ingest_url,
                        status = %status,
                        response_body = %body,
                        "control plane rejected event"
                    );
                }
                Err(e) => {
                    warn!(
                        event_id = %event_id,
                        ingest_url = %ingest_url,
                        error = %e,
                        "failed to send event to control plane"
                    );
                }
            }
        }

        warn!("event reporter worker stopped");
    });

    Ok(EventPublisher { tx })
}

impl EventPublisher {
    pub fn publish(&self, event: EventV1) {
        match self.tx.try_send(event) {
            Ok(()) => {}
            Err(TrySendError::Full(ev)) => {
                warn!(
                    event_id = %ev.event_id,
                    "event queue full; dropping event"
                );
            }
            Err(TrySendError::Closed(ev)) => {
                warn!(
                    event_id = %ev.event_id,
                    "event queue closed; dropping event"
                );
            }
        }
    }
}
