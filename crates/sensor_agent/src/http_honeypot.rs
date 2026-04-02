use crate::event_reporter::{now_rfc3339, EventPublisher};
use anyhow::{Context, Result};
use axum::{
    extract::{Extension, State},
    http::{HeaderMap, Method, StatusCode, Uri},
    response::{Html, IntoResponse, Response},
    routing::any,
    Router,
};
use hyper::{body::Incoming, server::conn::http1, service::service_fn, Request};
use hyper_util::rt::TokioIo;
use rcgen::generate_simple_self_signed;
use shared::{EventV1, Evidence, ServiceKind};
use std::{collections::HashSet, convert::Infallible, net::SocketAddr, sync::Arc};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio_rustls::{
    rustls::{Certificate, PrivateKey, ServerConfig},
    TlsAcceptor,
};
use tower::ServiceExt;
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct HttpHoneypotConfig {
    pub tenant_id: Uuid,
    pub sensor_id: Uuid,
    pub http_listen_addr: Option<String>,
    pub https_listen_addr: Option<String>,
    pub trap_paths: Vec<String>,
    pub publisher: EventPublisher,
}

#[derive(Debug, Clone)]
struct HttpTrapState {
    tenant_id: Uuid,
    sensor_id: Uuid,
    service_label: &'static str,
    service_kind: ServiceKind,
    trap_paths: Arc<HashSet<String>>,
    publisher: EventPublisher,
}

fn normalize_trap_path(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.starts_with('/') {
        trimmed.to_string()
    } else {
        format!("/{trimmed}")
    }
}

fn normalize_trap_paths(paths: &[String]) -> HashSet<String> {
    paths.iter().map(|p| normalize_trap_path(p)).collect()
}

fn build_state(
    tenant_id: Uuid,
    sensor_id: Uuid,
    service_label: &'static str,
    service_kind: ServiceKind,
    trap_paths: Arc<HashSet<String>>,
    publisher: EventPublisher,
) -> HttpTrapState {
    HttpTrapState {
        tenant_id,
        sensor_id,
        service_label,
        service_kind,
        trap_paths,
        publisher,
    }
}

fn build_router(state: HttpTrapState) -> Router {
    Router::new()
        .fallback(any(handle_honeypot_request))
        .with_state(state)
}

fn trap_response_for_path(path: &str) -> Response {
    match path {
        "/login" | "/wp-login.php" => (
            StatusCode::OK,
            Html(
                r#"<!doctype html>
<html lang="en">
  <head><title>Sign in</title></head>
  <body>
    <h1>Sign in</h1>
    <form method="post">
      <input type="text" name="username" placeholder="Username" />
      <input type="password" name="password" placeholder="Password" />
      <button type="submit">Login</button>
    </form>
  </body>
</html>"#,
            ),
        )
            .into_response(),
        "/admin" => (
            StatusCode::OK,
            Html(
                r#"<!doctype html>
<html lang="en">
  <head><title>Admin Console</title></head>
  <body>
    <h1>Admin Console</h1>
    <p>Restricted area</p>
  </body>
</html>"#,
            ),
        )
            .into_response(),
        _ => (StatusCode::OK, "ok").into_response(),
    }
}

async fn handle_honeypot_request(
    State(st): State<HttpTrapState>,
    Extension(remote): Extension<SocketAddr>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let path = uri.path().to_string();

    if !st.trap_paths.contains(&path) {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    }

    let user_agent = headers
        .get(axum::http::header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    let method_s = method.to_string();

    info!(
        service = st.service_label,
        event_kind = "http_trap_hit",
        tenant_id = %st.tenant_id,
        sensor_id = %st.sensor_id,
        src_ip = %remote.ip(),
        src_port = remote.port(),
        http_method = %method_s,
        http_path = %path,
        http_user_agent = user_agent.as_deref().unwrap_or("-"),
        "http trap request captured"
    );

    let event = EventV1::new(
        st.tenant_id,
        st.sensor_id,
        st.service_kind,
        remote.ip().to_string(),
        remote.port(),
        now_rfc3339(),
        Evidence {
            username: None,
            ssh_auth_method: None,
            http_user_agent: user_agent,
            http_method: Some(method_s),
            http_path: Some(path.clone()),
            decoy_hit: None,
            decoy_kind: None,
        },
    );

    st.publisher.publish(event);

    trap_response_for_path(&path)
}

async fn serve_connection<IO>(io: IO, remote_addr: SocketAddr, app: Router) -> Result<()>
where
    IO: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let service = service_fn(move |mut req: Request<Incoming>| {
        let app = app.clone();
        async move {
            req.extensions_mut().insert(remote_addr);
            let response = app
                .oneshot(req)
                .await
                .expect("router service should be infallible");
            Ok::<_, Infallible>(response)
        }
    });

    http1::Builder::new()
        .serve_connection(TokioIo::new(io), service)
        .await
        .context("http1 serve_connection failed")?;

    Ok(())
}

async fn run_plain_http_listener(
    tenant_id: Uuid,
    sensor_id: Uuid,
    listen_addr: String,
    trap_paths: Arc<HashSet<String>>,
    publisher: EventPublisher,
) -> Result<()> {
    let addr: SocketAddr = listen_addr
        .parse()
        .with_context(|| format!("invalid http listen_addr: {listen_addr}"))?;

    info!(
        service = "http",
        tenant_id = %tenant_id,
        sensor_id = %sensor_id,
        listen_addr = %addr,
        trap_paths = ?trap_paths,
        "http honeypot listening"
    );

    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("failed to bind http honeypot on {addr}"))?;

    let app = build_router(build_state(
        tenant_id,
        sensor_id,
        "http",
        ServiceKind::Http,
        trap_paths,
        publisher,
    ));

    loop {
        let (socket, remote_addr) = listener
            .accept()
            .await
            .with_context(|| format!("http accept failed on {addr}"))?;

        let app = app.clone();

        tokio::spawn(async move {
            if let Err(e) = serve_connection(socket, remote_addr, app).await {
                warn!(
                    error = %e,
                    service = "http",
                    src_ip = %remote_addr.ip(),
                    src_port = remote_addr.port(),
                    "http honeypot connection failed"
                );
            }
        });
    }
}

fn build_self_signed_tls_acceptor() -> Result<TlsAcceptor> {
    let cert = generate_simple_self_signed(vec!["localhost".to_string()])?;
    let cert_der = cert.serialize_der()?;
    let key_der = cert.serialize_private_key_der();

    let server_cfg = ServerConfig::builder()
        .with_safe_defaults()
        .with_no_client_auth()
        .with_single_cert(vec![Certificate(cert_der)], PrivateKey(key_der))
        .context("failed to build rustls server config")?;

    Ok(TlsAcceptor::from(Arc::new(server_cfg)))
}

async fn run_https_listener(
    tenant_id: Uuid,
    sensor_id: Uuid,
    listen_addr: String,
    trap_paths: Arc<HashSet<String>>,
    publisher: EventPublisher,
) -> Result<()> {
    let addr: SocketAddr = listen_addr
        .parse()
        .with_context(|| format!("invalid https listen_addr: {listen_addr}"))?;

    info!(
        service = "https",
        tenant_id = %tenant_id,
        sensor_id = %sensor_id,
        listen_addr = %addr,
        trap_paths = ?trap_paths,
        "https honeypot listening"
    );

    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("failed to bind https honeypot on {addr}"))?;

    let tls_acceptor = build_self_signed_tls_acceptor()?;
    let app = build_router(build_state(
        tenant_id,
        sensor_id,
        "https",
        ServiceKind::Https,
        trap_paths,
        publisher,
    ));

    loop {
        let (socket, remote_addr) = listener
            .accept()
            .await
            .with_context(|| format!("https accept failed on {addr}"))?;

        let tls_acceptor = tls_acceptor.clone();
        let app = app.clone();

        tokio::spawn(async move {
            match tls_acceptor.accept(socket).await {
                Ok(tls_stream) => {
                    if let Err(e) = serve_connection(tls_stream, remote_addr, app).await {
                        warn!(
                            error = %e,
                            service = "https",
                            src_ip = %remote_addr.ip(),
                            src_port = remote_addr.port(),
                            "https honeypot connection failed"
                        );
                    }
                }
                Err(e) => {
                    warn!(
                        error = %e,
                        service = "https",
                        src_ip = %remote_addr.ip(),
                        src_port = remote_addr.port(),
                        "https tls handshake failed"
                    );
                }
            }
        });
    }
}

pub async fn run_http_honeypots(cfg: HttpHoneypotConfig) -> Result<()> {
    let trap_paths = Arc::new(normalize_trap_paths(&cfg.trap_paths));

    let http_addr = cfg
        .http_listen_addr
        .clone()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let https_addr = cfg
        .https_listen_addr
        .clone()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    match (http_addr, https_addr) {
        (None, None) => Ok(()),
        (Some(http_addr), None) => {
            run_plain_http_listener(
                cfg.tenant_id,
                cfg.sensor_id,
                http_addr,
                trap_paths,
                cfg.publisher,
            )
            .await
        }
        (None, Some(https_addr)) => {
            run_https_listener(
                cfg.tenant_id,
                cfg.sensor_id,
                https_addr,
                trap_paths,
                cfg.publisher,
            )
            .await
        }
        (Some(http_addr), Some(https_addr)) => {
            let http_paths = Arc::clone(&trap_paths);
            let https_paths = Arc::clone(&trap_paths);

            let publisher_http = cfg.publisher.clone();
            let publisher_https = cfg.publisher.clone();

            tokio::try_join!(
                run_plain_http_listener(
                    cfg.tenant_id,
                    cfg.sensor_id,
                    http_addr,
                    http_paths,
                    publisher_http
                ),
                run_https_listener(
                    cfg.tenant_id,
                    cfg.sensor_id,
                    https_addr,
                    https_paths,
                    publisher_https
                ),
            )?;

            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_trap_path;

    #[test]
    fn normalizes_paths_with_leading_slash() {
        assert_eq!(normalize_trap_path("login"), "/login");
        assert_eq!(normalize_trap_path("/admin"), "/admin");
    }
}
