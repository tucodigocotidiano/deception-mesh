use anyhow::{anyhow, Result};
use argon2::{Argon2, PasswordHash, PasswordVerifier};
use axum::{
    async_trait,
    extract::{rejection::JsonRejection, ConnectInfo, FromRequestParts, Path, Query, State},
    http::{
        header::{HeaderValue, CONTENT_DISPOSITION, CONTENT_TYPE},
        request::Parts,
        HeaderMap, StatusCode,
    },
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use clap::Parser;
use deadpool_postgres::{Pool, Runtime};
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use reqwest::{Client as HttpClient, Url};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value as JsonValue};
use sha2::{Digest, Sha256};
use shared::EventV1;
use std::{
    fs,
    net::{IpAddr, SocketAddr},
    path::{Path as FsPath, PathBuf},
    str::FromStr,
    sync::Arc,
    time::{Duration as StdDuration, SystemTime, UNIX_EPOCH},
};
use tokio::time::sleep;
use tokio_postgres::{types::ToSql, NoTls, Row};
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;
use uuid::Uuid;

mod severity;

use severity::{decide_severity, SeverityConfig, SeverityDecision, SeverityLevel};

#[derive(Debug, Parser)]
#[command(
    name = "control_plane",
    version,
    about = "Deception Mesh Control Plane (MVP API)"
)]
struct Args {
    #[arg(long, default_value = "info")]
    log: String,

    #[arg(long, env = "BIND_ADDR", default_value = "0.0.0.0:8080")]
    bind: String,

    #[arg(long, env = "DATABASE_URL")]
    database_url: String,

    #[arg(long, env = "JWT_SECRET")]
    jwt_secret: String,

    #[arg(long, env = "JWT_TTL_SECONDS", default_value = "3600")]
    jwt_ttl_seconds: i64,

    #[arg(long, env = "DEV_ALLOW_X_USER_ID", default_value = "0")]
    dev_allow_x_user_id: u8,

    #[arg(long, env = "SENSOR_TOKEN_PEPPER")]
    sensor_token_pepper: String,

    #[arg(long, env = "SENSOR_ENROLL_TTL_SECONDS", default_value = "3600")]
    sensor_enroll_ttl_seconds: i64,

    #[arg(long, env = "SENSOR_OFFLINE_AFTER_SECONDS", default_value = "300")]
    sensor_offline_after_seconds: i64,

    #[arg(long, env = "MIGRATIONS_DIR", default_value = "/app/migrations")]
    migrations_dir: PathBuf,

    #[arg(long, env = "SEVERITY_REPEAT_WINDOW_SECONDS", default_value = "600")]
    severity_repeat_window_seconds: i64,

    #[arg(long, env = "SEVERITY_MEDIUM_THRESHOLD", default_value = "3")]
    severity_medium_threshold: i64,

    #[arg(long, env = "SEVERITY_HIGH_THRESHOLD", default_value = "5")]
    severity_high_threshold: i64,

    #[arg(long, env = "SEVERITY_CRITICAL_THRESHOLD", default_value = "10")]
    severity_critical_threshold: i64,

    #[arg(long, env = "SEVERITY_DECOY_LEVEL", default_value = "high")]
    severity_decoy_level: String,

    #[arg(
        long,
        env = "SEVERITY_CREDENTIAL_DECOY_LEVEL",
        default_value = "critical"
    )]
    severity_credential_decoy_level: String,

    #[arg(long, env = "WEBHOOK_TIMEOUT_SECONDS", default_value = "5")]
    webhook_timeout_seconds: u64,

    #[arg(long, env = "WEBHOOK_RETRY_MAX_ATTEMPTS", default_value = "4")]
    webhook_retry_max_attempts: i32,

    #[arg(long, env = "WEBHOOK_RETRY_BASE_DELAY_SECONDS", default_value = "2")]
    webhook_retry_base_delay_seconds: i64,

    #[arg(long, env = "WEBHOOK_RETRY_MAX_DELAY_SECONDS", default_value = "60")]
    webhook_retry_max_delay_seconds: i64,

    #[arg(
        long,
        env = "WEBHOOK_RETRY_POLL_INTERVAL_MILLIS",
        default_value = "1000"
    )]
    webhook_retry_poll_interval_millis: u64,
}

#[derive(Debug, Clone)]
struct WebhookRetryConfig {
    max_attempts: i32,
    base_delay_seconds: i64,
    max_delay_seconds: i64,
    poll_interval_millis: u64,
}

impl WebhookRetryConfig {
    fn validate(&self) -> Result<()> {
        if self.max_attempts < 4 {
            return Err(anyhow!(
                "WEBHOOK_RETRY_MAX_ATTEMPTS must be >= 4 (1 intento inicial + al menos 3 reintentos)"
            ));
        }

        if self.base_delay_seconds <= 0 {
            return Err(anyhow!("WEBHOOK_RETRY_BASE_DELAY_SECONDS must be > 0"));
        }

        if self.max_delay_seconds < self.base_delay_seconds {
            return Err(anyhow!(
                "WEBHOOK_RETRY_MAX_DELAY_SECONDS must be >= WEBHOOK_RETRY_BASE_DELAY_SECONDS"
            ));
        }

        if self.poll_interval_millis == 0 {
            return Err(anyhow!("WEBHOOK_RETRY_POLL_INTERVAL_MILLIS must be > 0"));
        }

        Ok(())
    }
}

#[derive(Clone)]
struct AppState {
    db: Pool,
    jwt_secret: Arc<String>,
    jwt_ttl_seconds: i64,
    dev_allow_x_user_id: bool,
    sensor_token_pepper: Arc<String>,
    sensor_enroll_ttl_seconds: i64,
    sensor_offline_after_seconds: i64,
    severity_cfg: Arc<SeverityConfig>,
    webhook_http: HttpClient,
    webhook_retry_cfg: Arc<WebhookRetryConfig>,
}

#[derive(Debug)]
enum AppError {
    Unauthorized(&'static str),
    Forbidden(&'static str),
    NotFound(&'static str),
    BadRequest(&'static str),
    ServiceUnavailable(&'static str),
    Internal(&'static str),
}

impl std::fmt::Display for AppError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unauthorized(msg) => write!(f, "unauthorized: {msg}"),
            Self::Forbidden(msg) => write!(f, "forbidden: {msg}"),
            Self::NotFound(msg) => write!(f, "not_found: {msg}"),
            Self::BadRequest(msg) => write!(f, "bad_request: {msg}"),
            Self::ServiceUnavailable(msg) => write!(f, "service_unavailable: {msg}"),
            Self::Internal(msg) => write!(f, "internal: {msg}"),
        }
    }
}

impl std::error::Error for AppError {}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        match self {
            Self::Unauthorized(msg) => (StatusCode::UNAUTHORIZED, msg).into_response(),
            Self::Forbidden(msg) => (StatusCode::FORBIDDEN, msg).into_response(),
            Self::NotFound(msg) => (StatusCode::NOT_FOUND, msg).into_response(),
            Self::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg).into_response(),
            Self::ServiceUnavailable(msg) => (StatusCode::SERVICE_UNAVAILABLE, msg).into_response(),
            Self::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg).into_response(),
        }
    }
}

type AppResult<T> = std::result::Result<T, AppError>;

fn init_tracing(log: &str) {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::new(log))
        .init();
}

fn now_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before unix epoch")
        .as_secs() as i64
}

fn now_rfc3339() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn sha256_hex(s: &str) -> String {
    let mut h = Sha256::new();
    h.update(s.as_bytes());
    hex::encode(h.finalize())
}

fn token_hash_hex(pepper: &str, token: &str) -> String {
    sha256_hex(&format!("{pepper}:{token}"))
}

fn new_plain_token(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::new_v4().simple())
}

fn trim_to_len(value: &str, max_len: usize) -> String {
    if value.chars().count() <= max_len {
        return value.to_string();
    }

    value.chars().take(max_len).collect()
}

async fn db_client(st: &AppState) -> AppResult<deadpool_postgres::Client> {
    st.db.get().await.map_err(|e| {
        warn!(error = %e, "db pool error");
        AppError::ServiceUnavailable("db-error")
    })
}

fn header_user_agent(headers: &HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

async fn query_opt_typed(
    st: &AppState,
    sql: &str,
    params: &[&(dyn ToSql + Sync)],
) -> AppResult<Option<Row>> {
    let client = db_client(st).await?;
    client.query_opt(sql, params).await.map_err(|e| {
        warn!(error = %e, query = sql, "query error");
        AppError::Internal("query-error")
    })
}

async fn query_typed(
    st: &AppState,
    sql: &str,
    params: &[&(dyn ToSql + Sync)],
) -> AppResult<Vec<Row>> {
    let client = db_client(st).await?;
    client.query(sql, params).await.map_err(|e| {
        warn!(error = %e, query = sql, "query error");
        AppError::Internal("query-error")
    })
}

async fn query_one_typed(
    st: &AppState,
    sql: &str,
    params: &[&(dyn ToSql + Sync)],
) -> AppResult<Row> {
    let client = db_client(st).await?;
    client.query_one(sql, params).await.map_err(|e| {
        warn!(error = %e, query = sql, "query error");
        AppError::Internal("db-write-error")
    })
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn ready(State(st): State<AppState>) -> impl IntoResponse {
    match db_client(&st).await {
        Ok(client) => match client.simple_query("SELECT 1").await {
            Ok(_) => (StatusCode::OK, "ready").into_response(),
            Err(e) => {
                warn!(error = %e, "ready query failed");
                (StatusCode::SERVICE_UNAVAILABLE, "db-not-ready").into_response()
            }
        },
        Err(e) => e.into_response(),
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct Claims {
    sub: String,
    iat: i64,
    exp: i64,
}

fn issue_jwt(secret: &str, user_id: Uuid, ttl_seconds: i64) -> Result<(String, i64)> {
    let iat = now_epoch_seconds();
    let exp = iat + ttl_seconds;

    let claims = Claims {
        sub: user_id.to_string(),
        iat,
        exp,
    };

    let mut header = Header::new(Algorithm::HS256);
    header.typ = Some("JWT".to_string());

    let token = encode(
        &header,
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;

    Ok((token, exp))
}

fn verify_jwt(secret: &str, token: &str) -> Result<Uuid> {
    let mut validation = Validation::new(Algorithm::HS256);
    validation.validate_exp = true;

    let data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &validation,
    )?;

    Ok(Uuid::parse_str(&data.claims.sub)?)
}

#[derive(Clone, Copy, Debug)]
struct AuthUser {
    user_id: Uuid,
}

#[async_trait]
impl FromRequestParts<AppState> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> AppResult<Self> {
        if state.dev_allow_x_user_id {
            if let Some(v) = parts.headers.get("x-user-id") {
                let s = v
                    .to_str()
                    .map_err(|_| AppError::Unauthorized("missing-or-invalid-token"))?;
                let user_id = Uuid::parse_str(s)
                    .map_err(|_| AppError::Unauthorized("missing-or-invalid-token"))?;
                return Ok(Self { user_id });
            }
        }

        let h = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .ok_or(AppError::Unauthorized("missing-or-invalid-token"))?
            .to_str()
            .map_err(|_| AppError::Unauthorized("missing-or-invalid-token"))?;

        let token = h
            .strip_prefix("Bearer ")
            .ok_or(AppError::Unauthorized("missing-or-invalid-token"))?;

        let user_id = verify_jwt(state.jwt_secret.as_ref(), token)
            .map_err(|_| AppError::Unauthorized("missing-or-invalid-token"))?;

        Ok(Self { user_id })
    }
}

#[derive(Clone, Debug)]
struct SensorToken(String);

#[async_trait]
impl FromRequestParts<AppState> for SensorToken {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, _state: &AppState) -> AppResult<Self> {
        let h = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .ok_or(AppError::Unauthorized("missing-or-invalid-sensor-token"))?
            .to_str()
            .map_err(|_| AppError::Unauthorized("missing-or-invalid-sensor-token"))?;

        let token = h
            .strip_prefix("Bearer ")
            .ok_or(AppError::Unauthorized("missing-or-invalid-sensor-token"))?
            .trim();

        if token.is_empty() || !token.starts_with("dm_sensor_") {
            return Err(AppError::Unauthorized("missing-or-invalid-sensor-token"));
        }

        Ok(Self(token.to_string()))
    }
}

async fn resolve_sensor_identity_by_token(st: &AppState, token: &str) -> AppResult<(Uuid, Uuid)> {
    let token_hash = token_hash_hex(st.sensor_token_pepper.as_ref(), token);

    let row = query_opt_typed(
        st,
        "SELECT id, tenant_id FROM sensors WHERE token_hash = $1",
        &[&token_hash],
    )
    .await?;

    let Some(row) = row else {
        return Err(AppError::Unauthorized("missing-or-invalid-sensor-token"));
    };

    let sensor_id: Uuid = row.get(0);
    let tenant_id: Uuid = row.get(1);
    Ok((sensor_id, tenant_id))
}

#[derive(Debug, Deserialize)]
struct LoginReq {
    email: String,
    password: String,
}

#[derive(Debug, Serialize)]
struct LoginResp {
    access_token: String,
    token_type: &'static str,
    expires_in: i64,
    user_id: Uuid,
}

async fn auth_login(
    State(st): State<AppState>,
    Json(body): Json<LoginReq>,
) -> AppResult<Json<LoginResp>> {
    let email = body.email.trim().to_lowercase();

    let row = query_opt_typed(
        &st,
        "SELECT id, password_hash FROM users WHERE email = $1",
        &[&email],
    )
    .await?;

    let Some(row) = row else {
        return Err(AppError::Unauthorized("invalid-credentials"));
    };

    let user_id: Uuid = row.get(0);
    let password_hash: Option<String> = row.get(1);

    let Some(phc) = password_hash else {
        return Err(AppError::Unauthorized("invalid-credentials"));
    };

    let parsed =
        PasswordHash::new(&phc).map_err(|_| AppError::Unauthorized("invalid-credentials"))?;

    if Argon2::default()
        .verify_password(body.password.as_bytes(), &parsed)
        .is_err()
    {
        return Err(AppError::Unauthorized("invalid-credentials"));
    }

    let (token, exp) =
        issue_jwt(st.jwt_secret.as_ref(), user_id, st.jwt_ttl_seconds).map_err(|e| {
            warn!(error = %e, "jwt issue error");
            AppError::Internal("token-error")
        })?;

    Ok(Json(LoginResp {
        access_token: token,
        token_type: "Bearer",
        expires_in: exp - now_epoch_seconds(),
        user_id,
    }))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RoleKind {
    Admin,
    Analyst,
    Readonly,
}

impl RoleKind {
    const fn can_write(self) -> bool {
        matches!(self, Self::Admin)
    }
}

fn parse_role_kind(s: &str) -> Option<RoleKind> {
    match s {
        "admin" => Some(RoleKind::Admin),
        "analyst" => Some(RoleKind::Analyst),
        "readonly" => Some(RoleKind::Readonly),
        _ => None,
    }
}

async fn membership_role(db: &Pool, user_id: Uuid, tenant_id: Uuid) -> Result<Option<RoleKind>> {
    let client = db.get().await?;
    let row = client
        .query_opt(
            "SELECT role::text FROM memberships WHERE tenant_id = $1 AND user_id = $2",
            &[&tenant_id, &user_id],
        )
        .await?;

    Ok(row
        .map(|r| r.get::<_, String>(0))
        .as_deref()
        .and_then(parse_role_kind))
}

async fn require_membership(db: &Pool, user_id: Uuid, tenant_id: Uuid) -> AppResult<RoleKind> {
    match membership_role(db, user_id, tenant_id).await {
        Ok(Some(role)) => Ok(role),
        Ok(None) => Err(AppError::NotFound("tenant-not-found")),
        Err(e) => {
            warn!(error = %e, "membership lookup failed");
            Err(AppError::ServiceUnavailable("db-error"))
        }
    }
}

async fn require_admin(db: &Pool, user_id: Uuid, tenant_id: Uuid) -> AppResult<()> {
    let role = require_membership(db, user_id, tenant_id).await?;
    if role.can_write() {
        Ok(())
    } else {
        Err(AppError::Forbidden("forbidden"))
    }
}

#[derive(Debug, Serialize)]
struct TenantRow {
    id: Uuid,
    name: String,
}

#[derive(Debug, Deserialize)]
struct WebhookUpdate {
    webhook_url: Option<String>,
    webhook_min_severity: Option<i32>,
}

#[derive(Debug, Serialize)]
struct WebhookSettingsOut {
    tenant_id: Uuid,
    webhook_url: Option<String>,
    webhook_min_severity: i32,
}

#[derive(Debug, Serialize)]
struct AuditRowOut {
    id: Uuid,
    tenant_id: Uuid,
    actor_user_id: Uuid,
    action: String,
    target_type: String,
    target_id: Option<Uuid>,
    ip: Option<String>,
    user_agent: Option<String>,
    details: JsonValue,
    created_at: String,
}

#[derive(Debug, Deserialize)]
struct AuditQuery {
    #[serde(default = "default_limit")]
    limit: i64,
}

const fn default_limit() -> i64 {
    50
}

const fn default_page() -> i64 {
    1
}

#[derive(Debug, Serialize)]
struct SensorRowOut {
    id: Uuid,
    tenant_id: Uuid,
    name: String,
    status: String,
    created_at: String,
    registered_at: Option<String>,
    last_seen: Option<String>,
    agent_version: Option<String>,
    rtt_ms: Option<i32>,
}

#[derive(Debug, Serialize)]
struct EnrollTokenOut {
    tenant_id: Uuid,
    enroll_token: String,
    expires_at: String,
}

#[derive(Debug, Deserialize)]
struct RegisterSensorReq {
    tenant_id: Uuid,
    enroll_token: String,
    name: String,
}

#[derive(Debug, Serialize)]
struct RegisterSensorResp {
    tenant_id: Uuid,
    sensor_id: Uuid,
    name: String,
    sensor_token: String,
}

#[derive(Debug, Deserialize)]
struct HeartbeatReq {
    agent_version: Option<String>,
    rtt_ms: Option<i32>,
}

#[derive(Debug, Serialize)]
struct HeartbeatResp {
    sensor_id: Uuid,
    tenant_id: Uuid,
    status: String,
    last_seen: String,
    agent_version: Option<String>,
    rtt_ms: Option<i32>,
}

#[derive(Debug, Serialize)]
struct IngestResp {
    event_id: Uuid,
    tenant_id: Uuid,
    sensor_id: Uuid,
    schema_version: u32,
    service: String,
    severity: String,
    severity_reason: String,
    attempt_count: i32,
    ingested: bool,
    webhook_delivery_id: Option<Uuid>,
}

#[derive(Debug, Deserialize, Clone)]
struct EventsQuery {
    tenant_id: Option<Uuid>,
    start: Option<String>,
    end: Option<String>,
    sensor_id: Option<Uuid>,
    service: Option<String>,
    severity: Option<String>,
    src_ip: Option<String>,
    text: Option<String>,

    #[serde(default = "default_limit")]
    limit: i64,

    #[serde(default = "default_page")]
    page: i64,
}

#[derive(Debug, Serialize, Clone)]
struct EventRowOut {
    id: Uuid,
    tenant_id: Uuid,
    sensor_id: Uuid,
    schema_version: i32,
    service: String,
    src_ip: String,
    src_port: i32,
    occurred_at: String,
    severity: String,
    severity_reason: String,
    attempt_count: i32,
    raw_event: JsonValue,
}

#[derive(Debug, Serialize)]
struct EventsListOut {
    tenant_id: Uuid,
    page: i64,
    limit: i64,
    returned: usize,
    has_more: bool,
    next_page: Option<i64>,
    items: Vec<EventRowOut>,
}

const EVENTS_EXPORT_HEADERS: [&str; 20] = [
    "event_id",
    "tenant_id",
    "sensor_id",
    "schema_version",
    "service",
    "src_ip",
    "src_port",
    "occurred_at",
    "severity",
    "severity_reason",
    "attempt_count",
    "event_timestamp_rfc3339",
    "username",
    "ssh_auth_method",
    "http_user_agent",
    "http_method",
    "http_path",
    "decoy_hit",
    "decoy_kind",
    "raw_event_json",
];

#[derive(Debug, Clone)]
struct ResolvedEventsFilters {
    start: Option<DateTime<Utc>>,
    end: Option<DateTime<Utc>>,
    sensor_id: Option<Uuid>,
    service: Option<String>,
    severity: Option<String>,
    src_ip: Option<String>,
    text: Option<String>,
}

#[derive(Debug)]
struct TenantWebhookTarget {
    url: String,
    min_severity: i32,
    tenant_name: String,
    sensor_name: String,
}

#[derive(Debug, Serialize)]
struct WebhookTenantOut {
    id: Uuid,
    name: String,
}

#[derive(Debug, Serialize)]
struct WebhookSensorOut {
    id: Uuid,
    name: String,
}

#[derive(Debug, Serialize)]
struct WebhookEventOut {
    id: Uuid,
    schema_version: u32,
    occurred_at: String,
    ingested_at: String,
    service: String,
    severity: String,
    severity_reason: String,
    attempt_count: i32,
    src_ip: String,
    src_port: u16,
    evidence: JsonValue,
}

#[derive(Debug, Serialize)]
struct WebhookEventEnvelope {
    version: &'static str,
    tenant: WebhookTenantOut,
    sensor: WebhookSensorOut,
    event: WebhookEventOut,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WebhookDeliveryStatus {
    Pending,
    InProgress,
    Retrying,
    Delivered,
    Failed,
}

impl WebhookDeliveryStatus {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::InProgress => "in_progress",
            Self::Retrying => "retrying",
            Self::Delivered => "delivered",
            Self::Failed => "failed",
        }
    }
}

impl std::fmt::Display for WebhookDeliveryStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl FromStr for WebhookDeliveryStatus {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "pending" => Ok(Self::Pending),
            "in_progress" => Ok(Self::InProgress),
            "retrying" => Ok(Self::Retrying),
            "delivered" => Ok(Self::Delivered),
            "failed" => Ok(Self::Failed),
            other => Err(anyhow!("invalid webhook delivery status: {other}")),
        }
    }
}

#[derive(Debug, Deserialize)]
struct WebhookDeliveriesQuery {
    event_id: Option<Uuid>,
    status: Option<String>,
    #[serde(default = "default_limit")]
    limit: i64,
}

#[derive(Debug, Serialize)]
struct WebhookDeliveryAttemptOut {
    id: Uuid,
    attempt_number: i32,
    success: bool,
    http_status: Option<i32>,
    error_message: Option<String>,
    started_at: String,
    finished_at: String,
}

#[derive(Debug, Serialize)]
struct WebhookDeliveryOut {
    id: Uuid,
    tenant_id: Uuid,
    event_id: Uuid,
    sensor_id: Uuid,
    target_url: String,
    status: String,
    attempt_count: i32,
    max_attempts: i32,
    next_attempt_at: Option<String>,
    last_attempt_at: Option<String>,
    delivered_at: Option<String>,
    last_status_code: Option<i32>,
    last_error: Option<String>,
    created_at: String,
    updated_at: String,
    attempts: Vec<WebhookDeliveryAttemptOut>,
}

#[derive(Debug)]
struct PendingWebhookDelivery {
    id: Uuid,
    tenant_id: Uuid,
    event_id: Uuid,
    sensor_id: Uuid,
    target_url: String,
    payload: JsonValue,
    attempt_count: i32,
    max_attempts: i32,
}

#[derive(Debug)]
struct DeliveryAttemptResult {
    success: bool,
    http_status: Option<i32>,
    error_message: Option<String>,
}

fn normalize_optional_filter(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

fn build_ilike_pattern(raw: Option<&str>) -> Option<String> {
    normalize_optional_filter(raw).map(|s| format!("%{s}%"))
}

fn parse_service_filter(raw: Option<&str>) -> AppResult<Option<String>> {
    match normalize_optional_filter(raw).map(|s| s.to_ascii_lowercase()) {
        None => Ok(None),
        Some(value) if matches!(value.as_str(), "ssh" | "http" | "https") => Ok(Some(value)),
        Some(_) => Err(AppError::BadRequest("invalid-service-filter")),
    }
}

fn parse_severity_filter(raw: Option<&str>) -> AppResult<Option<String>> {
    match normalize_optional_filter(raw) {
        None => Ok(None),
        Some(value) => {
            let parsed = SeverityLevel::from_str(&value)
                .map_err(|_| AppError::BadRequest("invalid-severity-filter"))?;
            Ok(Some(parsed.as_str().to_string()))
        }
    }
}

fn parse_delivery_status_filter(raw: Option<&str>) -> AppResult<Option<String>> {
    match normalize_optional_filter(raw) {
        None => Ok(None),
        Some(value) => {
            let parsed = WebhookDeliveryStatus::from_str(&value)
                .map_err(|_| AppError::BadRequest("invalid-webhook-delivery-status"))?;
            Ok(Some(parsed.as_str().to_string()))
        }
    }
}

fn parse_webhook_min_severity(raw: Option<i32>) -> AppResult<i32> {
    let value = raw.unwrap_or(2);
    if !(1..=4).contains(&value) {
        return Err(AppError::BadRequest("invalid-webhook-min-severity"));
    }
    Ok(value)
}

fn normalize_webhook_url(raw: Option<&str>) -> AppResult<Option<String>> {
    let Some(url) = normalize_optional_filter(raw) else {
        return Ok(None);
    };

    let parsed = Url::parse(&url).map_err(|_| AppError::BadRequest("invalid-webhook-url"))?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(AppError::BadRequest("invalid-webhook-url"));
    }

    Ok(Some(parsed.to_string()))
}

fn should_dispatch_webhook(level: SeverityLevel, min_severity: i32) -> bool {
    i32::from(level.rank()) >= min_severity
}

fn calculate_backoff_seconds(cfg: &WebhookRetryConfig, attempt_number: i32) -> i64 {
    let exponent = attempt_number.saturating_sub(1) as u32;
    let factor = 2_i64.saturating_pow(exponent.min(30));
    cfg.base_delay_seconds
        .saturating_mul(factor)
        .min(cfg.max_delay_seconds)
}

fn parse_optional_rfc3339(
    raw: Option<&str>,
    error_code: &'static str,
) -> AppResult<Option<DateTime<Utc>>> {
    let Some(value) = normalize_optional_filter(raw) else {
        return Ok(None);
    };

    let parsed = DateTime::parse_from_rfc3339(&value)
        .map_err(|_| AppError::BadRequest(error_code))?
        .with_timezone(&Utc);

    Ok(Some(parsed))
}

fn resolve_events_filters(q: &EventsQuery) -> AppResult<ResolvedEventsFilters> {
    let start = parse_optional_rfc3339(q.start.as_deref(), "invalid-start-rfc3339")?;
    let end = parse_optional_rfc3339(q.end.as_deref(), "invalid-end-rfc3339")?;

    if let (Some(start_ts), Some(end_ts)) = (start, end) {
        if start_ts > end_ts {
            return Err(AppError::BadRequest("start-after-end"));
        }
    }

    Ok(ResolvedEventsFilters {
        start,
        end,
        sensor_id: q.sensor_id,
        service: parse_service_filter(q.service.as_deref())?,
        severity: parse_severity_filter(q.severity.as_deref())?,
        src_ip: normalize_optional_filter(q.src_ip.as_deref()),
        text: build_ilike_pattern(q.text.as_deref()),
    })
}

fn map_event_row(r: Row) -> EventRowOut {
    EventRowOut {
        id: r.get(0),
        tenant_id: r.get(1),
        sensor_id: r.get(2),
        schema_version: r.get(3),
        service: r.get(4),
        src_ip: r.get(5),
        src_port: r.get(6),
        occurred_at: r.get(7),
        severity: r.get(8),
        severity_reason: r.get(9),
        attempt_count: r.get(10),
        raw_event: r.get(11),
    }
}

async fn query_events_for_tenant_paginated(
    st: &AppState,
    tenant_id: Uuid,
    filters: &ResolvedEventsFilters,
    limit: i64,
    offset: i64,
) -> AppResult<Vec<EventRowOut>> {
    let rows = query_typed(
        st,
        r#"
        SELECT
          id,
          tenant_id,
          sensor_id,
          schema_version,
          service,
          src_ip,
          src_port,
          occurred_at::text,
          severity,
          severity_reason,
          attempt_count,
          raw_event
        FROM events
        WHERE tenant_id = $1
          AND ($2::timestamptz IS NULL OR occurred_at >= $2)
          AND ($3::timestamptz IS NULL OR occurred_at <= $3)
          AND ($4::uuid IS NULL OR sensor_id = $4)
          AND ($5::text IS NULL OR service = $5)
          AND ($6::text IS NULL OR severity = $6)
          AND ($7::text IS NULL OR src_ip = $7)
          AND (
            $8::text IS NULL
            OR src_ip ILIKE $8
            OR service ILIKE $8
            OR severity ILIKE $8
            OR COALESCE(severity_reason, '') ILIKE $8
            OR raw_event::text ILIKE $8
          )
        ORDER BY occurred_at DESC, id DESC
        LIMIT $9 OFFSET $10
        "#,
        &[
            &tenant_id,
            &filters.start,
            &filters.end,
            &filters.sensor_id,
            &filters.service,
            &filters.severity,
            &filters.src_ip,
            &filters.text,
            &limit,
            &offset,
        ],
    )
    .await?;

    Ok(rows.into_iter().map(map_event_row).collect())
}

async fn query_events_for_tenant_export(
    st: &AppState,
    tenant_id: Uuid,
    filters: &ResolvedEventsFilters,
) -> AppResult<Vec<EventRowOut>> {
    let rows = query_typed(
        st,
        r#"
        SELECT
          id,
          tenant_id,
          sensor_id,
          schema_version,
          service,
          src_ip,
          src_port,
          occurred_at::text,
          severity,
          severity_reason,
          attempt_count,
          raw_event
        FROM events
        WHERE tenant_id = $1
          AND ($2::timestamptz IS NULL OR occurred_at >= $2)
          AND ($3::timestamptz IS NULL OR occurred_at <= $3)
          AND ($4::uuid IS NULL OR sensor_id = $4)
          AND ($5::text IS NULL OR service = $5)
          AND ($6::text IS NULL OR severity = $6)
          AND ($7::text IS NULL OR src_ip = $7)
          AND (
            $8::text IS NULL
            OR src_ip ILIKE $8
            OR service ILIKE $8
            OR severity ILIKE $8
            OR COALESCE(severity_reason, '') ILIKE $8
            OR raw_event::text ILIKE $8
          )
        ORDER BY occurred_at DESC, id DESC
        "#,
        &[
            &tenant_id,
            &filters.start,
            &filters.end,
            &filters.sensor_id,
            &filters.service,
            &filters.severity,
            &filters.src_ip,
            &filters.text,
        ],
    )
    .await?;

    Ok(rows.into_iter().map(map_event_row).collect())
}

fn csv_escape_cell(value: &str) -> String {
    if value.contains(',') || value.contains('"') || value.contains('\n') || value.contains('\r') {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_string()
    }
}

fn push_csv_line(out: &mut String, cells: &[String]) {
    for (idx, cell) in cells.iter().enumerate() {
        if idx > 0 {
            out.push(',');
        }
        out.push_str(&csv_escape_cell(cell));
    }
    out.push('\n');
}

fn csv_cells_for_event_row(row: &EventRowOut) -> Vec<String> {
    let parsed = serde_json::from_value::<EventV1>(row.raw_event.clone()).ok();

    let timestamp_rfc3339 = parsed
        .as_ref()
        .map(|ev| ev.timestamp_rfc3339.clone())
        .unwrap_or_default();

    let username = parsed
        .as_ref()
        .and_then(|ev| ev.evidence.username.clone())
        .unwrap_or_default();

    let ssh_auth_method = parsed
        .as_ref()
        .and_then(|ev| ev.evidence.ssh_auth_method.clone())
        .unwrap_or_default();

    let http_user_agent = parsed
        .as_ref()
        .and_then(|ev| ev.evidence.http_user_agent.clone())
        .unwrap_or_default();

    let http_method = parsed
        .as_ref()
        .and_then(|ev| ev.evidence.http_method.clone())
        .unwrap_or_default();

    let http_path = parsed
        .as_ref()
        .and_then(|ev| ev.evidence.http_path.clone())
        .unwrap_or_default();

    let decoy_hit = parsed
        .as_ref()
        .and_then(|ev| ev.evidence.decoy_hit.map(|v| v.to_string()))
        .unwrap_or_default();

    let decoy_kind = parsed
        .as_ref()
        .and_then(|ev| ev.evidence.decoy_kind.clone())
        .unwrap_or_default();

    vec![
        row.id.to_string(),
        row.tenant_id.to_string(),
        row.sensor_id.to_string(),
        row.schema_version.to_string(),
        row.service.clone(),
        row.src_ip.clone(),
        row.src_port.to_string(),
        row.occurred_at.clone(),
        row.severity.clone(),
        row.severity_reason.clone(),
        row.attempt_count.to_string(),
        timestamp_rfc3339,
        username,
        ssh_auth_method,
        http_user_agent,
        http_method,
        http_path,
        decoy_hit,
        decoy_kind,
        row.raw_event.to_string(),
    ]
}

fn render_events_csv(rows: &[EventRowOut]) -> String {
    let mut out = String::new();

    let headers = EVENTS_EXPORT_HEADERS
        .iter()
        .map(|value| (*value).to_string())
        .collect::<Vec<_>>();
    push_csv_line(&mut out, &headers);

    for row in rows {
        let cells = csv_cells_for_event_row(row);
        push_csv_line(&mut out, &cells);
    }

    out
}

fn build_export_filename(tenant_id: Uuid) -> String {
    format!(
        "deception_mesh_events_{}_{}.csv",
        tenant_id,
        Utc::now().format("%Y%m%dT%H%M%SZ")
    )
}

fn csv_download_response(filename: &str, body: String) -> AppResult<Response> {
    let mut headers = HeaderMap::new();
    headers.insert(
        CONTENT_TYPE,
        HeaderValue::from_static("text/csv; charset=utf-8"),
    );

    let content_disposition = format!("attachment; filename=\"{filename}\"");
    let content_disposition_value = HeaderValue::from_str(&content_disposition)
        .map_err(|_| AppError::Internal("invalid-csv-filename"))?;
    headers.insert(CONTENT_DISPOSITION, content_disposition_value);

    Ok((headers, body).into_response())
}

#[allow(clippy::too_many_arguments)]
async fn audit_insert(
    db: &Pool,
    tenant_id: Uuid,
    actor_user_id: Uuid,
    action: &str,
    target_type: &str,
    target_id: Option<Uuid>,
    ip: Option<IpAddr>,
    user_agent: Option<String>,
    details: JsonValue,
) -> Result<()> {
    let client = db.get().await?;
    client
        .execute(
            r#"
            INSERT INTO audit_log (
              tenant_id, actor_user_id, action, target_type, target_id,
              ip, user_agent, details
            )
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
            "#,
            &[
                &tenant_id,
                &actor_user_id,
                &action,
                &target_type,
                &target_id,
                &ip,
                &user_agent,
                &details,
            ],
        )
        .await?;
    Ok(())
}

async fn list_tenants(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
) -> AppResult<Json<Vec<TenantRow>>> {
    let rows = query_typed(
        &st,
        r#"
        SELECT t.id, t.name
        FROM tenants t
        JOIN memberships m ON m.tenant_id = t.id
        WHERE m.user_id = $1
        ORDER BY t.created_at DESC
        "#,
        &[&user_id],
    )
    .await?;

    Ok(Json(
        rows.into_iter()
            .map(|r| TenantRow {
                id: r.get(0),
                name: r.get(1),
            })
            .collect(),
    ))
}

async fn get_webhook(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Path(tenant_id): Path<Uuid>,
) -> AppResult<Json<WebhookSettingsOut>> {
    let _ = require_membership(&st.db, user_id, tenant_id).await?;

    let row = query_opt_typed(
        &st,
        "SELECT webhook_url, webhook_min_severity FROM tenant_settings WHERE tenant_id = $1",
        &[&tenant_id],
    )
    .await?;

    let out = match row {
        Some(r) => WebhookSettingsOut {
            tenant_id,
            webhook_url: r.get(0),
            webhook_min_severity: r.get(1),
        },
        None => WebhookSettingsOut {
            tenant_id,
            webhook_url: None,
            webhook_min_severity: 2,
        },
    };

    Ok(Json(out))
}

async fn put_webhook(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Path(tenant_id): Path<Uuid>,
    ConnectInfo(remote): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<WebhookUpdate>,
) -> AppResult<Json<WebhookSettingsOut>> {
    require_admin(&st.db, user_id, tenant_id).await?;

    let before = query_opt_typed(
        &st,
        "SELECT webhook_url, webhook_min_severity FROM tenant_settings WHERE tenant_id = $1",
        &[&tenant_id],
    )
    .await?
    .map(|r| {
        json!({
          "webhook_url": r.get::<_, Option<String>>(0),
          "webhook_min_severity": r.get::<_, i32>(1),
        })
    });

    let webhook_url = normalize_webhook_url(body.webhook_url.as_deref())?;
    let sev = parse_webhook_min_severity(body.webhook_min_severity)?;

    let row = query_one_typed(
        &st,
        r#"
        INSERT INTO tenant_settings (tenant_id, webhook_url, webhook_min_severity, updated_at)
        VALUES ($1, $2, $3, now())
        ON CONFLICT (tenant_id)
        DO UPDATE SET webhook_url = EXCLUDED.webhook_url,
                      webhook_min_severity = EXCLUDED.webhook_min_severity,
                      updated_at = now()
        RETURNING tenant_id, webhook_url, webhook_min_severity
        "#,
        &[&tenant_id, &webhook_url, &sev],
    )
    .await?;

    let out = WebhookSettingsOut {
        tenant_id: row.get(0),
        webhook_url: row.get(1),
        webhook_min_severity: row.get(2),
    };

    let details = json!({
        "before": before.unwrap_or(json!(null)),
        "after": {
            "webhook_url": out.webhook_url.clone(),
            "webhook_min_severity": out.webhook_min_severity,
        }
    });

    if let Err(e) = audit_insert(
        &st.db,
        tenant_id,
        user_id,
        "tenant.webhook.update",
        "tenant_settings",
        Some(tenant_id),
        Some(remote.ip()),
        header_user_agent(&headers),
        details,
    )
    .await
    {
        warn!(error = %e, "audit insert failed");
    }

    Ok(Json(out))
}

async fn get_audit(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Path(tenant_id): Path<Uuid>,
    Query(q): Query<AuditQuery>,
) -> AppResult<Json<Vec<AuditRowOut>>> {
    let _ = require_membership(&st.db, user_id, tenant_id).await?;
    let limit = q.limit.clamp(1, 200);

    let rows = query_typed(
        &st,
        r#"
        SELECT
          id, tenant_id, actor_user_id, action, target_type, target_id,
          ip::text, user_agent, details, created_at::text
        FROM audit_log
        WHERE tenant_id = $1
        ORDER BY created_at DESC
        LIMIT $2
        "#,
        &[&tenant_id, &limit],
    )
    .await?;

    Ok(Json(
        rows.into_iter()
            .map(|r| AuditRowOut {
                id: r.get(0),
                tenant_id: r.get(1),
                actor_user_id: r.get(2),
                action: r.get(3),
                target_type: r.get(4),
                target_id: r.get(5),
                ip: r.get(6),
                user_agent: r.get(7),
                details: r.get(8),
                created_at: r.get(9),
            })
            .collect(),
    ))
}

async fn create_sensor_enroll_token(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Path(tenant_id): Path<Uuid>,
    ConnectInfo(remote): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> AppResult<(StatusCode, Json<EnrollTokenOut>)> {
    require_admin(&st.db, user_id, tenant_id).await?;

    let enroll_token = new_plain_token("dm_enroll");
    let enroll_hash = token_hash_hex(st.sensor_token_pepper.as_ref(), &enroll_token);

    let ttl = st.sensor_enroll_ttl_seconds.max(60);
    let expires_epoch = (now_epoch_seconds() + ttl) as f64;

    let row = query_one_typed(
        &st,
        r#"
        INSERT INTO sensor_enroll_tokens (tenant_id, token_hash, created_by, expires_at)
        VALUES ($1, $2, $3, to_timestamp($4::double precision))
        RETURNING id, tenant_id, expires_at::text
        "#,
        &[&tenant_id, &enroll_hash, &user_id, &expires_epoch],
    )
    .await?;

    let enroll_id: Uuid = row.get(0);
    let tenant_id_out: Uuid = row.get(1);
    let expires_at: String = row.get(2);

    if let Err(e) = audit_insert(
        &st.db,
        tenant_id,
        user_id,
        "sensor.enroll_token.create",
        "sensor_enroll_tokens",
        Some(enroll_id),
        Some(remote.ip()),
        header_user_agent(&headers),
        json!({
            "after": {
                "enroll_id": enroll_id,
                "expires_at": expires_at,
                "token_hint": format!("...{}", &enroll_token[enroll_token.len().saturating_sub(6)..]),
            }
        }),
    )
    .await
    {
        warn!(error = %e, "audit insert failed");
    }

    Ok((
        StatusCode::CREATED,
        Json(EnrollTokenOut {
            tenant_id: tenant_id_out,
            enroll_token,
            expires_at,
        }),
    ))
}

async fn sensors_register(
    State(st): State<AppState>,
    ConnectInfo(remote): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<RegisterSensorReq>,
) -> AppResult<(StatusCode, Json<RegisterSensorResp>)> {
    let name = body.name.trim();
    if name.is_empty() {
        return Err(AppError::BadRequest("name-required"));
    }

    let enroll_token = body.enroll_token.trim();
    if enroll_token.is_empty() {
        return Err(AppError::BadRequest("enroll_token-required"));
    }

    let enroll_hash = token_hash_hex(st.sensor_token_pepper.as_ref(), enroll_token);

    let mut client = db_client(&st).await?;
    let tx = client.transaction().await.map_err(|e| {
        warn!(error = %e, "tx start error");
        AppError::Internal("db-error")
    })?;

    let row = tx
        .query_opt(
            r#"
            SELECT id
            FROM sensor_enroll_tokens
            WHERE tenant_id = $1
              AND token_hash = $2
              AND used_at IS NULL
              AND expires_at > now()
            FOR UPDATE
            "#,
            &[&body.tenant_id, &enroll_hash],
        )
        .await
        .map_err(|e| {
            warn!(error = %e, "enroll token select error");
            AppError::Internal("query-error")
        })?;

    let Some(row) = row else {
        return Err(AppError::Unauthorized("invalid-or-expired-enroll-token"));
    };

    let enroll_id: Uuid = row.get(0);

    let sensor_token = new_plain_token("dm_sensor");
    let sensor_hash = token_hash_hex(st.sensor_token_pepper.as_ref(), &sensor_token);

    let sensor_row = tx
        .query_one(
            r#"
            INSERT INTO sensors (tenant_id, name, token_hash, status, created_at, registered_at)
            VALUES ($1, $2, $3, 'active', now(), now())
            RETURNING id, tenant_id, name
            "#,
            &[&body.tenant_id, &name, &sensor_hash],
        )
        .await
        .map_err(|e| {
            warn!(error = %e, "insert sensor error");
            AppError::Internal("db-write-error")
        })?;

    tx.execute(
        "UPDATE sensor_enroll_tokens SET used_at = now() WHERE id = $1",
        &[&enroll_id],
    )
    .await
    .map_err(|e| {
        warn!(error = %e, "mark enroll used error");
        AppError::Internal("db-write-error")
    })?;

    tx.commit().await.map_err(|e| {
        warn!(error = %e, "tx commit error");
        AppError::Internal("db-error")
    })?;

    let sensor_id: Uuid = sensor_row.get(0);

    info!(
        tenant_id = %body.tenant_id,
        sensor_id = %sensor_id,
        remote_ip = %remote.ip(),
        user_agent = headers
            .get(axum::http::header::USER_AGENT)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("-"),
        "sensor registered"
    );

    Ok((
        StatusCode::CREATED,
        Json(RegisterSensorResp {
            tenant_id: body.tenant_id,
            sensor_id,
            name: name.to_string(),
            sensor_token,
        }),
    ))
}

async fn sensor_heartbeat(
    SensorToken(token): SensorToken,
    State(st): State<AppState>,
    Path(sensor_id): Path<Uuid>,
    Json(body): Json<HeartbeatReq>,
) -> AppResult<Json<HeartbeatResp>> {
    let token_hash = token_hash_hex(st.sensor_token_pepper.as_ref(), &token);

    let row = query_opt_typed(
        &st,
        "SELECT tenant_id FROM sensors WHERE id = $1 AND token_hash = $2",
        &[&sensor_id, &token_hash],
    )
    .await?;

    let Some(row) = row else {
        return Err(AppError::Unauthorized("missing-or-invalid-sensor-token"));
    };

    let tenant_id: Uuid = row.get(0);

    let agent_version = body
        .agent_version
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let row = query_one_typed(
        &st,
        r#"
        UPDATE sensors
        SET last_seen = now(),
            agent_version = COALESCE($3, agent_version),
            rtt_ms = COALESCE($4, rtt_ms),
            status = 'active'
        WHERE id = $1 AND tenant_id = $2
        RETURNING id, tenant_id, last_seen::text, agent_version, rtt_ms
        "#,
        &[&sensor_id, &tenant_id, &agent_version, &body.rtt_ms],
    )
    .await?;

    Ok(Json(HeartbeatResp {
        sensor_id: row.get(0),
        tenant_id: row.get(1),
        status: "active".to_string(),
        last_seen: row.get(2),
        agent_version: row.get(3),
        rtt_ms: row.get(4),
    }))
}

async fn list_sensors(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Path(tenant_id): Path<Uuid>,
) -> AppResult<Json<Vec<SensorRowOut>>> {
    let _ = require_membership(&st.db, user_id, tenant_id).await?;
    let threshold = st.sensor_offline_after_seconds.max(10);

    let rows = query_typed(
        &st,
        r#"
        SELECT
          id,
          tenant_id,
          name,
          CASE
            WHEN last_seen IS NOT NULL
                 AND (now() - last_seen) <= ($2::bigint * interval '1 second')
              THEN 'active'
            WHEN last_seen IS NOT NULL
                 AND (now() - last_seen) > ($2::bigint * interval '1 second')
              THEN 'offline'
            WHEN last_seen IS NULL
                 AND registered_at IS NOT NULL
                 AND (now() - registered_at) <= ($2::bigint * interval '1 second')
              THEN 'active'
            ELSE 'offline'
          END AS status,
          created_at::text,
          registered_at::text,
          last_seen::text,
          agent_version,
          rtt_ms
        FROM sensors
        WHERE tenant_id = $1
        ORDER BY created_at DESC
        "#,
        &[&tenant_id, &threshold],
    )
    .await?;

    Ok(Json(
        rows.into_iter()
            .map(|r| SensorRowOut {
                id: r.get(0),
                tenant_id: r.get(1),
                name: r.get(2),
                status: r.get(3),
                created_at: r.get(4),
                registered_at: r.get(5),
                last_seen: r.get(6),
                agent_version: r.get(7),
                rtt_ms: r.get(8),
            })
            .collect(),
    ))
}

async fn count_recent_similar_events(
    st: &AppState,
    event: &EventV1,
    occurred_at: DateTime<Utc>,
) -> AppResult<i64> {
    let window_start = occurred_at - Duration::seconds(st.severity_cfg.repeat_window_seconds);
    let service = event.service.as_str().to_string();

    let row = query_one_typed(
        st,
        r#"
        SELECT COUNT(*)::bigint
        FROM events
        WHERE tenant_id = $1
          AND sensor_id = $2
          AND service = $3
          AND src_ip = $4
          AND occurred_at >= $5
          AND occurred_at <= $6
          AND id <> $7
        "#,
        &[
            &event.tenant_id,
            &event.sensor_id,
            &service,
            &event.src_ip,
            &window_start,
            &occurred_at,
            &event.event_id,
        ],
    )
    .await?;

    Ok(row.get(0))
}

async fn load_tenant_webhook_target(
    st: &AppState,
    tenant_id: Uuid,
    sensor_id: Uuid,
) -> AppResult<Option<TenantWebhookTarget>> {
    let row = query_opt_typed(
        st,
        r#"
        SELECT
          ts.webhook_url,
          ts.webhook_min_severity,
          t.name,
          s.name
        FROM tenant_settings ts
        JOIN tenants t ON t.id = ts.tenant_id
        JOIN sensors s ON s.id = $2 AND s.tenant_id = ts.tenant_id
        WHERE ts.tenant_id = $1
        "#,
        &[&tenant_id, &sensor_id],
    )
    .await?;

    let Some(row) = row else {
        return Ok(None);
    };

    let webhook_url: Option<String> = row.get(0);
    let Some(url) = normalize_optional_filter(webhook_url.as_deref()) else {
        return Ok(None);
    };

    Ok(Some(TenantWebhookTarget {
        url,
        min_severity: row.get(1),
        tenant_name: row.get(2),
        sensor_name: row.get(3),
    }))
}

fn build_webhook_envelope(
    target: &TenantWebhookTarget,
    event: &EventV1,
    occurred_at: &DateTime<Utc>,
    severity_decision: &SeverityDecision,
) -> AppResult<WebhookEventEnvelope> {
    let evidence = serde_json::to_value(&event.evidence).map_err(|e| {
        warn!(error = %e, event_id = %event.event_id, "serialize webhook evidence failed");
        AppError::Internal("serialize-webhook-payload-error")
    })?;

    Ok(WebhookEventEnvelope {
        version: "deception_mesh.event.v1",
        tenant: WebhookTenantOut {
            id: event.tenant_id,
            name: target.tenant_name.clone(),
        },
        sensor: WebhookSensorOut {
            id: event.sensor_id,
            name: target.sensor_name.clone(),
        },
        event: WebhookEventOut {
            id: event.event_id,
            schema_version: event.schema_version,
            occurred_at: occurred_at.to_rfc3339_opts(SecondsFormat::Millis, true),
            ingested_at: now_rfc3339(),
            service: event.service.as_str().to_string(),
            severity: severity_decision.level.as_str().to_string(),
            severity_reason: severity_decision.reason.clone(),
            attempt_count: severity_decision.attempt_count,
            src_ip: event.src_ip.clone(),
            src_port: event.src_port,
            evidence,
        },
    })
}

async fn enqueue_event_webhook_delivery(
    st: &AppState,
    event: &EventV1,
    occurred_at: &DateTime<Utc>,
    severity_decision: &SeverityDecision,
) -> AppResult<Option<Uuid>> {
    let Some(target) = load_tenant_webhook_target(st, event.tenant_id, event.sensor_id).await?
    else {
        info!(
            event_id = %event.event_id,
            tenant_id = %event.tenant_id,
            sensor_id = %event.sensor_id,
            "webhook queue skipped: tenant has no webhook configured"
        );
        return Ok(None);
    };

    if !should_dispatch_webhook(severity_decision.level, target.min_severity) {
        info!(
            event_id = %event.event_id,
            tenant_id = %event.tenant_id,
            sensor_id = %event.sensor_id,
            severity = %severity_decision.level,
            webhook_min_severity = target.min_severity,
            "webhook queue skipped: severity below tenant threshold"
        );
        return Ok(None);
    }

    let payload = serde_json::to_value(build_webhook_envelope(
        &target,
        event,
        occurred_at,
        severity_decision,
    )?)
    .map_err(|e| {
        warn!(error = %e, event_id = %event.event_id, "serialize webhook envelope failed");
        AppError::Internal("serialize-webhook-payload-error")
    })?;

    let row = query_opt_typed(
        st,
        r#"
        INSERT INTO webhook_deliveries (
          tenant_id, event_id, sensor_id, target_url, payload,
          status, max_attempts, attempt_count, next_attempt_at,
          created_at, updated_at
        )
        VALUES ($1,$2,$3,$4,$5,$6,$7,0,now(),now(),now())
        ON CONFLICT (event_id, target_url) DO NOTHING
        RETURNING id
        "#,
        &[
            &event.tenant_id,
            &event.event_id,
            &event.sensor_id,
            &target.url,
            &payload,
            &WebhookDeliveryStatus::Pending.as_str(),
            &st.webhook_retry_cfg.max_attempts,
        ],
    )
    .await?;

    let delivery_id = row.map(|r| r.get::<_, Uuid>(0));

    if let Some(delivery_id) = delivery_id {
        info!(
            event_id = %event.event_id,
            delivery_id = %delivery_id,
            tenant_id = %event.tenant_id,
            sensor_id = %event.sensor_id,
            target_url = %target.url,
            max_attempts = st.webhook_retry_cfg.max_attempts,
            "webhook delivery queued"
        );
        Ok(Some(delivery_id))
    } else {
        info!(
            event_id = %event.event_id,
            tenant_id = %event.tenant_id,
            sensor_id = %event.sensor_id,
            target_url = %target.url,
            "webhook delivery already queued"
        );
        Ok(None)
    }
}

async fn send_webhook_payload(
    client: &HttpClient,
    url: &str,
    payload: &JsonValue,
) -> DeliveryAttemptResult {
    match client.post(url).json(payload).send().await {
        Ok(response) => {
            let status = i32::from(response.status().as_u16());
            if response.status().is_success() {
                DeliveryAttemptResult {
                    success: true,
                    http_status: Some(status),
                    error_message: None,
                }
            } else {
                let body = response.text().await.unwrap_or_default();
                DeliveryAttemptResult {
                    success: false,
                    http_status: Some(status),
                    error_message: Some(trim_to_len(
                        &format!("non-success-status={} body={}", status, body),
                        2_000,
                    )),
                }
            }
        }
        Err(e) => DeliveryAttemptResult {
            success: false,
            http_status: None,
            error_message: Some(trim_to_len(&e.to_string(), 2_000)),
        },
    }
}

async fn claim_due_webhook_delivery(st: &AppState) -> AppResult<Option<PendingWebhookDelivery>> {
    let mut client = db_client(st).await?;
    let tx = client.transaction().await.map_err(|e| {
        warn!(error = %e, "webhook delivery tx start error");
        AppError::Internal("db-error")
    })?;

    let row = tx
        .query_opt(
            r#"
            SELECT
              id,
              tenant_id,
              event_id,
              sensor_id,
              target_url,
              payload,
              attempt_count,
              max_attempts
            FROM webhook_deliveries
            WHERE status IN ('pending', 'retrying')
              AND next_attempt_at <= now()
            ORDER BY next_attempt_at ASC, created_at ASC
            LIMIT 1
            FOR UPDATE SKIP LOCKED
            "#,
            &[],
        )
        .await
        .map_err(|e| {
            warn!(error = %e, "claim webhook delivery select error");
            AppError::Internal("query-error")
        })?;

    let Some(row) = row else {
        tx.commit().await.map_err(|e| {
            warn!(error = %e, "webhook delivery tx commit error");
            AppError::Internal("db-error")
        })?;
        return Ok(None);
    };

    let delivery_id: Uuid = row.get(0);

    tx.execute(
        r#"
        UPDATE webhook_deliveries
        SET status = 'in_progress', updated_at = now()
        WHERE id = $1
        "#,
        &[&delivery_id],
    )
    .await
    .map_err(|e| {
        warn!(error = %e, delivery_id = %delivery_id, "claim webhook delivery update error");
        AppError::Internal("db-write-error")
    })?;

    tx.commit().await.map_err(|e| {
        warn!(error = %e, delivery_id = %delivery_id, "webhook delivery tx commit error");
        AppError::Internal("db-error")
    })?;

    Ok(Some(PendingWebhookDelivery {
        id: delivery_id,
        tenant_id: row.get(1),
        event_id: row.get(2),
        sensor_id: row.get(3),
        target_url: row.get(4),
        payload: row.get(5),
        attempt_count: row.get(6),
        max_attempts: row.get(7),
    }))
}

async fn finalize_webhook_delivery_attempt(
    st: &AppState,
    delivery: &PendingWebhookDelivery,
    result: &DeliveryAttemptResult,
) -> AppResult<()> {
    let attempt_number = delivery.attempt_count.saturating_add(1);
    let error_message = result
        .error_message
        .as_deref()
        .map(|v| trim_to_len(v, 2_000));

    let mut client = db_client(st).await?;
    let tx = client.transaction().await.map_err(|e| {
        warn!(error = %e, delivery_id = %delivery.id, "webhook finalize tx start error");
        AppError::Internal("db-error")
    })?;

    let attempt_id = Uuid::new_v4();
    tx.execute(
        r#"
        INSERT INTO webhook_delivery_attempts (
          id, delivery_id, tenant_id, event_id, attempt_number,
          success, http_status, error_message, started_at, finished_at
        )
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,now(),now())
        "#,
        &[
            &attempt_id,
            &delivery.id,
            &delivery.tenant_id,
            &delivery.event_id,
            &attempt_number,
            &result.success,
            &result.http_status,
            &error_message,
        ],
    )
    .await
    .map_err(|e| {
        warn!(error = %e, delivery_id = %delivery.id, "webhook attempt insert error");
        AppError::Internal("db-write-error")
    })?;

    if result.success {
        tx.execute(
            r#"
            UPDATE webhook_deliveries
            SET
              status = 'delivered',
              attempt_count = $2,
              last_attempt_at = now(),
              delivered_at = now(),
              last_status_code = $3,
              last_error = NULL,
              next_attempt_at = NULL,
              updated_at = now()
            WHERE id = $1
            "#,
            &[&delivery.id, &attempt_number, &result.http_status],
        )
        .await
        .map_err(|e| {
            warn!(error = %e, delivery_id = %delivery.id, "webhook delivery success update error");
            AppError::Internal("db-write-error")
        })?;
    } else if attempt_number < delivery.max_attempts {
        let delay_seconds =
            calculate_backoff_seconds(st.webhook_retry_cfg.as_ref(), attempt_number);
        tx.execute(
            r#"
            UPDATE webhook_deliveries
            SET
              status = 'retrying',
              attempt_count = $2,
              last_attempt_at = now(),
              last_status_code = $3,
              last_error = $4,
              next_attempt_at = now() + ($5::bigint * interval '1 second'),
              updated_at = now()
            WHERE id = $1
            "#,
            &[
                &delivery.id,
                &attempt_number,
                &result.http_status,
                &error_message,
                &delay_seconds,
            ],
        )
        .await
        .map_err(|e| {
            warn!(error = %e, delivery_id = %delivery.id, "webhook delivery retry update error");
            AppError::Internal("db-write-error")
        })?;
    } else {
        tx.execute(
            r#"
            UPDATE webhook_deliveries
            SET
              status = 'failed',
              attempt_count = $2,
              last_attempt_at = now(),
              last_status_code = $3,
              last_error = $4,
              next_attempt_at = NULL,
              updated_at = now()
            WHERE id = $1
            "#,
            &[
                &delivery.id,
                &attempt_number,
                &result.http_status,
                &error_message,
            ],
        )
        .await
        .map_err(|e| {
            warn!(error = %e, delivery_id = %delivery.id, "webhook delivery failure update error");
            AppError::Internal("db-write-error")
        })?;
    }

    tx.commit().await.map_err(|e| {
        warn!(error = %e, delivery_id = %delivery.id, "webhook finalize tx commit error");
        AppError::Internal("db-error")
    })?;

    Ok(())
}

async fn webhook_delivery_worker(st: AppState) {
    let poll_interval =
        StdDuration::from_millis(st.webhook_retry_cfg.poll_interval_millis.max(100));

    info!(
        max_attempts = st.webhook_retry_cfg.max_attempts,
        base_delay_seconds = st.webhook_retry_cfg.base_delay_seconds,
        max_delay_seconds = st.webhook_retry_cfg.max_delay_seconds,
        poll_interval_millis = st.webhook_retry_cfg.poll_interval_millis,
        "webhook delivery worker started"
    );

    loop {
        match claim_due_webhook_delivery(&st).await {
            Ok(Some(delivery)) => {
                let next_attempt = delivery.attempt_count.saturating_add(1);
                info!(
                    delivery_id = %delivery.id,
                    event_id = %delivery.event_id,
                    tenant_id = %delivery.tenant_id,
                    sensor_id = %delivery.sensor_id,
                    target_url = %delivery.target_url,
                    attempt_number = next_attempt,
                    max_attempts = delivery.max_attempts,
                    "processing webhook delivery"
                );

                let result =
                    send_webhook_payload(&st.webhook_http, &delivery.target_url, &delivery.payload)
                        .await;

                if let Err(e) = finalize_webhook_delivery_attempt(&st, &delivery, &result).await {
                    warn!(
                        error = %e,
                        delivery_id = %delivery.id,
                        event_id = %delivery.event_id,
                        "failed to persist webhook delivery attempt"
                    );
                } else if result.success {
                    info!(
                        delivery_id = %delivery.id,
                        event_id = %delivery.event_id,
                        attempt_number = next_attempt,
                        http_status = ?result.http_status,
                        "webhook delivery completed"
                    );
                } else {
                    warn!(
                        delivery_id = %delivery.id,
                        event_id = %delivery.event_id,
                        attempt_number = next_attempt,
                        http_status = ?result.http_status,
                        error = result.error_message.as_deref().unwrap_or("unknown-error"),
                        "webhook delivery attempt failed"
                    );
                }

                continue;
            }
            Ok(None) => {}
            Err(e) => {
                warn!(error = %e, "webhook delivery worker loop error");
            }
        }

        sleep(poll_interval).await;
    }
}

async fn events_ingest(
    SensorToken(token): SensorToken,
    State(st): State<AppState>,
    payload: Result<Json<EventV1>, JsonRejection>,
) -> AppResult<(StatusCode, Json<IngestResp>)> {
    let Json(event) = payload.map_err(|_| AppError::BadRequest("invalid-event-payload"))?;

    event.validate_contract().map_err(|e| {
        warn!(error = %e, event_id = %event.event_id, "event contract validation failed");
        AppError::BadRequest("invalid-event-contract")
    })?;

    let (sensor_id_db, tenant_id_db) = resolve_sensor_identity_by_token(&st, &token).await?;

    if sensor_id_db != event.sensor_id || tenant_id_db != event.tenant_id {
        return Err(AppError::Unauthorized("sensor-token-payload-mismatch"));
    }

    let occurred_at: DateTime<Utc> = DateTime::parse_from_rfc3339(&event.timestamp_rfc3339)
        .map_err(|_| AppError::BadRequest("invalid-timestamp-rfc3339"))?
        .with_timezone(&Utc);

    let prior_attempts = count_recent_similar_events(&st, &event, occurred_at).await?;
    let severity_decision = decide_severity(st.severity_cfg.as_ref(), &event, prior_attempts);

    let raw_event = serde_json::to_value(&event).map_err(|e| {
        warn!(error = %e, "serialize event failed");
        AppError::Internal("serialize-event-error")
    })?;

    let schema_version = i32::try_from(event.schema_version)
        .map_err(|_| AppError::BadRequest("invalid-schema-version"))?;
    let src_port = i32::from(event.src_port);
    let service = event.service.as_str().to_string();
    let severity = severity_decision.level.as_str().to_string();
    let severity_reason = severity_decision.reason.clone();
    let attempt_count = severity_decision.attempt_count;

    let inserted = query_opt_typed(
        &st,
        r#"
        INSERT INTO events (
          id, tenant_id, sensor_id, schema_version, service,
          src_ip, src_port, occurred_at, raw_event,
          severity, severity_reason, attempt_count
        )
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
        ON CONFLICT (id) DO NOTHING
        RETURNING id
        "#,
        &[
            &event.event_id,
            &event.tenant_id,
            &event.sensor_id,
            &schema_version,
            &service,
            &event.src_ip,
            &src_port,
            &occurred_at,
            &raw_event,
            &severity,
            &severity_reason,
            &attempt_count,
        ],
    )
    .await?;

    let ingested = inserted.is_some();
    let status = if ingested {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };

    let webhook_delivery_id = if ingested {
        match enqueue_event_webhook_delivery(&st, &event, &occurred_at, &severity_decision).await {
            Ok(value) => value,
            Err(e) => {
                warn!(
                    error = %e,
                    event_id = %event.event_id,
                    tenant_id = %event.tenant_id,
                    sensor_id = %event.sensor_id,
                    "webhook queue scheduling failed"
                );
                None
            }
        }
    } else {
        None
    };

    info!(
        event_id = %event.event_id,
        tenant_id = %event.tenant_id,
        sensor_id = %event.sensor_id,
        service = %service,
        severity = %severity,
        severity_reason = %severity_reason,
        attempt_count = attempt_count,
        ingested = ingested,
        webhook_delivery_id = ?webhook_delivery_id,
        "event ingested"
    );

    Ok((
        status,
        Json(IngestResp {
            event_id: event.event_id,
            tenant_id: event.tenant_id,
            sensor_id: event.sensor_id,
            schema_version: event.schema_version,
            service,
            severity,
            severity_reason,
            attempt_count,
            ingested,
            webhook_delivery_id,
        }),
    ))
}

async fn list_events(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Query(q): Query<EventsQuery>,
) -> AppResult<Json<EventsListOut>> {
    let tenant_id = q
        .tenant_id
        .ok_or(AppError::BadRequest("tenant_id-required"))?;
    let out = list_events_for_tenant(user_id, &st, tenant_id, &q).await?;
    Ok(Json(out))
}

async fn list_events_scoped(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Path(tenant_id): Path<Uuid>,
    Query(q): Query<EventsQuery>,
) -> AppResult<Json<EventsListOut>> {
    if let Some(query_tenant_id) = q.tenant_id {
        if query_tenant_id != tenant_id {
            return Err(AppError::BadRequest("tenant_id-mismatch"));
        }
    }

    let out = list_events_for_tenant(user_id, &st, tenant_id, &q).await?;
    Ok(Json(out))
}

async fn export_events_csv(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Query(q): Query<EventsQuery>,
) -> AppResult<Response> {
    let tenant_id = q
        .tenant_id
        .ok_or(AppError::BadRequest("tenant_id-required"))?;

    export_events_csv_for_tenant(user_id, &st, tenant_id, &q).await
}

async fn export_events_csv_scoped(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Path(tenant_id): Path<Uuid>,
    Query(q): Query<EventsQuery>,
) -> AppResult<Response> {
    if let Some(query_tenant_id) = q.tenant_id {
        if query_tenant_id != tenant_id {
            return Err(AppError::BadRequest("tenant_id-mismatch"));
        }
    }

    export_events_csv_for_tenant(user_id, &st, tenant_id, &q).await
}

async fn export_events_csv_for_tenant(
    user_id: Uuid,
    st: &AppState,
    tenant_id: Uuid,
    q: &EventsQuery,
) -> AppResult<Response> {
    let _ = require_membership(&st.db, user_id, tenant_id).await?;
    let filters = resolve_events_filters(q)?;
    let rows = query_events_for_tenant_export(st, tenant_id, &filters).await?;

    let csv_body = render_events_csv(&rows);
    let filename = build_export_filename(tenant_id);

    csv_download_response(&filename, csv_body)
}

async fn list_events_for_tenant(
    user_id: Uuid,
    st: &AppState,
    tenant_id: Uuid,
    q: &EventsQuery,
) -> AppResult<EventsListOut> {
    let _ = require_membership(&st.db, user_id, tenant_id).await?;
    let filters = resolve_events_filters(q)?;

    let limit = q.limit.clamp(1, 200);
    let page = q.page.max(1);
    let offset = (page - 1).saturating_mul(limit);
    let fetch_limit = limit.saturating_add(1);

    let mut items =
        query_events_for_tenant_paginated(st, tenant_id, &filters, fetch_limit, offset).await?;

    let has_more = (items.len() as i64) > limit;
    if has_more {
        let _ = items.pop();
    }

    let returned = items.len();
    let next_page = has_more.then_some(page + 1);

    Ok(EventsListOut {
        tenant_id,
        page,
        limit,
        returned,
        has_more,
        next_page,
        items,
    })
}

async fn list_webhook_deliveries(
    AuthUser { user_id }: AuthUser,
    State(st): State<AppState>,
    Path(tenant_id): Path<Uuid>,
    Query(q): Query<WebhookDeliveriesQuery>,
) -> AppResult<Json<Vec<WebhookDeliveryOut>>> {
    let _ = require_membership(&st.db, user_id, tenant_id).await?;
    let limit = q.limit.clamp(1, 200);
    let status = parse_delivery_status_filter(q.status.as_deref())?;

    let rows = query_typed(
        &st,
        r#"
        SELECT
          id,
          tenant_id,
          event_id,
          sensor_id,
          target_url,
          status,
          attempt_count,
          max_attempts,
          next_attempt_at::text,
          last_attempt_at::text,
          delivered_at::text,
          last_status_code,
          last_error,
          created_at::text,
          updated_at::text
        FROM webhook_deliveries
        WHERE tenant_id = $1
          AND ($2::uuid IS NULL OR event_id = $2)
          AND ($3::text IS NULL OR status = $3)
        ORDER BY created_at DESC, id DESC
        LIMIT $4
        "#,
        &[&tenant_id, &q.event_id, &status, &limit],
    )
    .await?;

    let mut deliveries = Vec::with_capacity(rows.len());

    for row in rows {
        let delivery_id: Uuid = row.get(0);
        let attempt_rows = query_typed(
            &st,
            r#"
            SELECT
              id,
              attempt_number,
              success,
              http_status,
              error_message,
              started_at::text,
              finished_at::text
            FROM webhook_delivery_attempts
            WHERE delivery_id = $1
            ORDER BY attempt_number ASC, started_at ASC
            "#,
            &[&delivery_id],
        )
        .await?;

        let attempts = attempt_rows
            .into_iter()
            .map(|a| WebhookDeliveryAttemptOut {
                id: a.get(0),
                attempt_number: a.get(1),
                success: a.get(2),
                http_status: a.get(3),
                error_message: a.get(4),
                started_at: a.get(5),
                finished_at: a.get(6),
            })
            .collect();

        deliveries.push(WebhookDeliveryOut {
            id: delivery_id,
            tenant_id: row.get(1),
            event_id: row.get(2),
            sensor_id: row.get(3),
            target_url: row.get(4),
            status: row.get(5),
            attempt_count: row.get(6),
            max_attempts: row.get(7),
            next_attempt_at: row.get(8),
            last_attempt_at: row.get(9),
            delivered_at: row.get(10),
            last_status_code: row.get(11),
            last_error: row.get(12),
            created_at: row.get(13),
            updated_at: row.get(14),
            attempts,
        });
    }

    Ok(Json(deliveries))
}

fn list_sql_migration_files(dir: &FsPath) -> Result<Vec<PathBuf>> {
    if !dir.exists() {
        return Ok(Vec::new());
    }

    let mut files = Vec::new();

    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.is_file()
            && path
                .extension()
                .and_then(|s| s.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("sql"))
        {
            files.push(path);
        }
    }

    files.sort();
    Ok(files)
}

async fn apply_sql_migrations(st: &AppState, dir: &FsPath) -> Result<()> {
    let files = list_sql_migration_files(dir)?;

    if files.is_empty() {
        warn!(migrations_dir = %dir.display(), "no sql migrations found");
        return Ok(());
    }

    let client = st.db.get().await?;

    for file in files {
        let sql = fs::read_to_string(&file)?;
        client.batch_execute(&sql).await?;
        info!(file = %file.display(), "sql migration applied");
    }

    Ok(())
}

fn pool_from_database_url(database_url: &str) -> Result<Pool> {
    let mut pg_cfg: tokio_postgres::Config = database_url.parse()?;
    pg_cfg.application_name("deceptionmesh-control-plane");

    let mgr = deadpool_postgres::Manager::new(pg_cfg, NoTls);
    Ok(Pool::builder(mgr)
        .max_size(16)
        .runtime(Runtime::Tokio1)
        .build()?)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    init_tracing(&args.log);

    let severity_cfg = SeverityConfig {
        repeat_window_seconds: args.severity_repeat_window_seconds,
        medium_threshold: args.severity_medium_threshold,
        high_threshold: args.severity_high_threshold,
        critical_threshold: args.severity_critical_threshold,
        decoy_level: args.severity_decoy_level.parse::<SeverityLevel>()?,
        credential_decoy_level: args
            .severity_credential_decoy_level
            .parse::<SeverityLevel>()?,
    };
    severity_cfg.validate()?;

    let webhook_retry_cfg = WebhookRetryConfig {
        max_attempts: args.webhook_retry_max_attempts,
        base_delay_seconds: args.webhook_retry_base_delay_seconds,
        max_delay_seconds: args.webhook_retry_max_delay_seconds,
        poll_interval_millis: args.webhook_retry_poll_interval_millis,
    };
    webhook_retry_cfg.validate()?;

    let webhook_http = HttpClient::builder()
        .timeout(StdDuration::from_secs(args.webhook_timeout_seconds.max(1)))
        .build()?;

    let state = AppState {
        db: pool_from_database_url(&args.database_url)?,
        jwt_secret: Arc::new(args.jwt_secret),
        jwt_ttl_seconds: args.jwt_ttl_seconds,
        dev_allow_x_user_id: args.dev_allow_x_user_id != 0,
        sensor_token_pepper: Arc::new(args.sensor_token_pepper),
        sensor_enroll_ttl_seconds: args.sensor_enroll_ttl_seconds,
        sensor_offline_after_seconds: args.sensor_offline_after_seconds,
        severity_cfg: Arc::new(severity_cfg),
        webhook_http,
        webhook_retry_cfg: Arc::new(webhook_retry_cfg),
    };

    info!(
        migrations_dir = %args.migrations_dir.display(),
        "applying sql migrations"
    );
    apply_sql_migrations(&state, &args.migrations_dir).await?;

    info!(
        repeat_window_seconds = state.severity_cfg.repeat_window_seconds,
        medium_threshold = state.severity_cfg.medium_threshold,
        high_threshold = state.severity_cfg.high_threshold,
        critical_threshold = state.severity_cfg.critical_threshold,
        decoy_level = %state.severity_cfg.decoy_level,
        credential_decoy_level = %state.severity_cfg.credential_decoy_level,
        webhook_timeout_seconds = args.webhook_timeout_seconds,
        webhook_retry_max_attempts = state.webhook_retry_cfg.max_attempts,
        webhook_retry_base_delay_seconds = state.webhook_retry_cfg.base_delay_seconds,
        webhook_retry_max_delay_seconds = state.webhook_retry_cfg.max_delay_seconds,
        webhook_retry_poll_interval_millis = state.webhook_retry_cfg.poll_interval_millis,
        "severity engine and webhook retries configured"
    );

    let worker_state = state.clone();
    tokio::spawn(async move {
        webhook_delivery_worker(worker_state).await;
    });

    let app = Router::new()
        .route("/health", get(health))
        .route("/ready", get(ready))
        .route("/auth/login", post(auth_login))
        .route("/sensors/register", post(sensors_register))
        .route("/sensors/:sensor_id/heartbeat", post(sensor_heartbeat))
        .route("/events", get(list_events))
        .route("/events/export.csv", get(export_events_csv))
        .route("/events/ingest", post(events_ingest))
        .route("/v1/tenants", get(list_tenants))
        .route(
            "/v1/tenants/:tenant_id/webhook",
            get(get_webhook).put(put_webhook),
        )
        .route("/v1/tenants/:tenant_id/audit", get(get_audit))
        .route("/v1/tenants/:tenant_id/events", get(list_events_scoped))
        .route(
            "/v1/tenants/:tenant_id/events/export.csv",
            get(export_events_csv_scoped),
        )
        .route(
            "/v1/tenants/:tenant_id/webhook-deliveries",
            get(list_webhook_deliveries),
        )
        .route(
            "/v1/tenants/:tenant_id/sensors/enroll-token",
            post(create_sensor_enroll_token),
        )
        .route("/v1/tenants/:tenant_id/sensors", get(list_sensors))
        .with_state(state);

    let addr: SocketAddr = args.bind.parse()?;
    info!(%addr, "control_plane api listening");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        let _ = tokio::signal::ctrl_c().await;
        info!("shutdown signal received");
    })
    .await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use shared::{Evidence, ServiceKind};

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
            "203.0.113.77",
            2222,
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

    fn default_severity_cfg() -> SeverityConfig {
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
    fn token_hash_is_deterministic() {
        let a = token_hash_hex("pepper", "abc");
        let b = token_hash_hex("pepper", "abc");
        assert_eq!(a, b);
    }

    #[test]
    fn role_parser_rejects_unknown_roles() {
        assert_eq!(parse_role_kind("admin"), Some(RoleKind::Admin));
        assert_eq!(parse_role_kind("owner"), None);
    }

    #[test]
    fn severity_escalates_on_repeated_attempts() {
        let cfg = default_severity_cfg();
        let ev = base_http_event();

        let d1 = decide_severity(&cfg, &ev, 0);
        let d3 = decide_severity(&cfg, &ev, 2);
        let d5 = decide_severity(&cfg, &ev, 4);
        let d10 = decide_severity(&cfg, &ev, 9);

        assert_eq!(d1.level, SeverityLevel::Low);
        assert_eq!(d3.level, SeverityLevel::Medium);
        assert_eq!(d5.level, SeverityLevel::High);
        assert_eq!(d10.level, SeverityLevel::Critical);
    }

    #[test]
    fn credential_decoy_overrides_to_critical() {
        let cfg = default_severity_cfg();
        let ev = base_ssh_decoy_event();

        let decision = decide_severity(&cfg, &ev, 0);
        assert_eq!(decision.level, SeverityLevel::Critical);
        assert!(decision.reason.contains("decoy_credential_hit"));
    }

    #[test]
    fn parse_service_filter_accepts_known_values() {
        assert_eq!(
            parse_service_filter(Some(" HTTP ")).expect("valid service filter"),
            Some("http".to_string())
        );
    }

    #[test]
    fn parse_service_filter_rejects_unknown_values() {
        assert!(matches!(
            parse_service_filter(Some("smtp")),
            Err(AppError::BadRequest("invalid-service-filter"))
        ));
    }

    #[test]
    fn parse_severity_filter_rejects_unknown_values() {
        assert!(matches!(
            parse_severity_filter(Some("urgent")),
            Err(AppError::BadRequest("invalid-severity-filter"))
        ));
    }

    #[test]
    fn parse_webhook_min_severity_rejects_out_of_range() {
        assert!(matches!(
            parse_webhook_min_severity(Some(0)),
            Err(AppError::BadRequest("invalid-webhook-min-severity"))
        ));
        assert!(matches!(
            parse_webhook_min_severity(Some(5)),
            Err(AppError::BadRequest("invalid-webhook-min-severity"))
        ));
    }

    #[test]
    fn normalize_webhook_url_accepts_http_and_https() {
        assert_eq!(
            normalize_webhook_url(Some("http://localhost:18080/hook"))
                .expect("http webhook url should be valid"),
            Some("http://localhost:18080/hook".to_string())
        );

        assert!(
            normalize_webhook_url(Some("ftp://localhost/hook")).is_err(),
            "ftp should be rejected"
        );
    }

    #[test]
    fn webhook_threshold_matches_expected_ranks() {
        assert!(!should_dispatch_webhook(SeverityLevel::Low, 2));
        assert!(should_dispatch_webhook(SeverityLevel::Medium, 2));
        assert!(should_dispatch_webhook(SeverityLevel::High, 3));
        assert!(!should_dispatch_webhook(SeverityLevel::High, 4));
        assert!(should_dispatch_webhook(SeverityLevel::Critical, 4));
    }

    #[test]
    fn webhook_backoff_grows_and_caps() {
        let cfg = WebhookRetryConfig {
            max_attempts: 4,
            base_delay_seconds: 2,
            max_delay_seconds: 10,
            poll_interval_millis: 1_000,
        };

        assert_eq!(calculate_backoff_seconds(&cfg, 1), 2);
        assert_eq!(calculate_backoff_seconds(&cfg, 2), 4);
        assert_eq!(calculate_backoff_seconds(&cfg, 3), 8);
        assert_eq!(calculate_backoff_seconds(&cfg, 4), 10);
    }

    #[test]
    fn parse_delivery_status_filter_rejects_unknown_values() {
        assert!(matches!(
            parse_delivery_status_filter(Some("queued")),
            Err(AppError::BadRequest("invalid-webhook-delivery-status"))
        ));
    }

    #[test]
    fn csv_escape_wraps_special_chars() {
        assert_eq!(csv_escape_cell("simple"), "simple");
        assert_eq!(csv_escape_cell("a,b"), "\"a,b\"");
        assert_eq!(csv_escape_cell("a\"b"), "\"a\"\"b\"");
        assert_eq!(csv_escape_cell("a\nb"), "\"a\nb\"");
    }

    #[test]
    fn render_events_csv_contains_headers_and_values() {
        let ev = base_http_event();

        let row = EventRowOut {
            id: ev.event_id,
            tenant_id: ev.tenant_id,
            sensor_id: ev.sensor_id,
            schema_version: i32::try_from(ev.schema_version).expect("schema_version fits in i32"),
            service: ev.service.as_str().to_string(),
            src_ip: ev.src_ip.clone(),
            src_port: i32::from(ev.src_port),
            occurred_at: ev.timestamp_rfc3339.clone(),
            severity: "low".to_string(),
            severity_reason: "default_low".to_string(),
            attempt_count: 1,
            raw_event: serde_json::to_value(&ev).expect("serialize event"),
        };

        let csv = render_events_csv(&[row]);
        let mut lines = csv.lines();

        let header = lines.next().expect("csv header");
        assert!(header.contains("event_id"));
        assert!(header.contains("http_path"));
        assert!(csv.contains("/login"));
        assert!(csv.contains("203.0.113.55"));
    }
}
