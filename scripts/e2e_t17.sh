#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${API:-http://localhost:8080}"
T12_SSH_PORT="${T12_SSH_PORT:-2222}"
T12_SSH_USER="${T12_SSH_USER:-decoy-user}"
T13_HTTP_PORT="${T13_HTTP_PORT:-18081}"
T13_HTTP_USER_AGENT="${T13_HTTP_USER_AGENT:-dm-e2e-t17-http/1.0}"

ok()   { echo -e "✅ $*"; }
info() { echo -e "ℹ️  $*"; }
die()  { echo -e "❌ $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Falta dependencia: $1"; }

uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
  fi
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

http_code() { curl -sS -o /dev/null -w "%{http_code}" "$@"; }

HAVE_STDBUF=0

cleanup() {
  if [ -n "${T17_AGENT_PID:-}" ]; then
    kill "$T17_AGENT_PID" 2>/dev/null || true
    wait "$T17_AGENT_PID" 2>/dev/null || true
  fi

  if [ -n "${T17_TMP_CFG:-}" ] && [ -f "${T17_TMP_CFG:-}" ]; then
    rm -f "$T17_TMP_CFG"
  fi

  if [ -n "${T17_LOG_FILE:-}" ] && [ -f "${T17_LOG_FILE:-}" ]; then
    rm -f "$T17_LOG_FILE"
  fi

  if [ -n "${RESP_BODY_FILE:-}" ] && [ -f "${RESP_BODY_FILE:-}" ]; then
    rm -f "$RESP_BODY_FILE"
  fi

  if [ -n "${STATUS_FILE:-}" ] && [ -f "${STATUS_FILE:-}" ]; then
    rm -f "$STATUS_FILE"
  fi
}
trap cleanup EXIT

wait_for_log() {
  local pattern="$1"
  local file="$2"
  local tries="${3:-20}"

  for _ in $(seq 1 "$tries"); do
    if grep -qi "$pattern" "$file"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

prepare_sensor_cfg() {
  local out_file="$1"
  local tenant_id="$2"
  local sensor_id="$3"
  local sensor_token="$4"
  local base_url="$5"
  local heartbeat_interval="$6"
  local ssh_listen_addr="$7"
  local http_listen_addr="$8"

  cat > "$out_file" <<EOF
[sensor]
tenant_id = "$tenant_id"
sensor_id = "$sensor_id"
sensor_token = "$sensor_token"

[control_plane]
base_url = "$base_url"
heartbeat_path = "/sensors/{sensor_id}/heartbeat"
ingest_path = "/events/ingest"
request_timeout_seconds = 5

[runtime]
heartbeat_interval_seconds = $heartbeat_interval
max_queue = 10000

[logging]
level = "info"
format = "pretty"

[honeypots]
ssh_listen_addr = "$ssh_listen_addr"
ssh_banner = "OpenSSH_8.9p1 Ubuntu-3ubuntu0.10"
http_listen_addr = "$http_listen_addr"
https_listen_addr = ""
http_trap_paths = ["/login", "/admin", "/wp-login.php"]
EOF
}

need docker
need curl
need jq
need cargo
need timeout
need ssh
need grep
need sed
need mktemp

if command -v stdbuf >/dev/null 2>&1; then
  HAVE_STDBUF=1
fi

info "API=$API"
docker compose up -d --build >/dev/null

HC="$(http_code -i "$API/health")"
RC="$(http_code -i "$API/ready")"
[ "$HC" = "200" ] || die "/health no devuelve 200 (got $HC)"
[ "$RC" = "200" ] || die "/ready no devuelve 200 (got $RC)"
ok "Stack OK (/health y /ready)"

DB_URL="$(docker compose exec -T control_plane printenv DATABASE_URL | tr -d '\r')"
DB_NAME="$(echo "$DB_URL" | sed -E 's#.*/##')"
PGUSER="$(docker compose exec -T postgres printenv POSTGRES_USER | tr -d '\r')"

LOGIN_JSON="$(curl -sS -X POST "$API/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@acme.com","password":"admin"}')"

TOKEN="$(echo "$LOGIN_JSON" | jq -r .access_token)"
USER_ID="$(echo "$LOGIN_JSON" | jq -r .user_id)"

[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || die "No se obtuvo access_token"
[ -n "$USER_ID" ] && [ "$USER_ID" != "null" ] || die "No se obtuvo user_id"
ok "Login OK"

TENANT_A="$(uuid)"
docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"INSERT INTO tenants (id, name) VALUES ('$TENANT_A','Acme T17') ON CONFLICT DO NOTHING;" >/dev/null

docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"INSERT INTO memberships (tenant_id, user_id, role)
 VALUES ('$TENANT_A','$USER_ID','admin')
 ON CONFLICT DO NOTHING;" >/dev/null

ENROLL_JSON="$(curl -sS -X POST "$API/v1/tenants/$TENANT_A/sensors/enroll-token" \
  -H "Authorization: Bearer $TOKEN")"

ENROLL_TOKEN="$(echo "$ENROLL_JSON" | jq -r .enroll_token)"
[ -n "$ENROLL_TOKEN" ] && [ "$ENROLL_TOKEN" != "null" ] || die "No se obtuvo enroll_token"

REGISTER_JSON="$(curl -sS -X POST "$API/sensors/register" \
  -H "Content-Type: application/json" \
  -d "{\"tenant_id\":\"$TENANT_A\",\"enroll_token\":\"$ENROLL_TOKEN\",\"name\":\"sensor-t17\"}")"

SENSOR_ID="$(echo "$REGISTER_JSON" | jq -r .sensor_id)"
SENSOR_TOKEN="$(echo "$REGISTER_JSON" | jq -r .sensor_token)"

[ -n "$SENSOR_ID" ] && [ "$SENSOR_ID" != "null" ] || die "No se obtuvo sensor_id"
[ -n "$SENSOR_TOKEN" ] && [ "$SENSOR_TOKEN" != "null" ] || die "No se obtuvo sensor_token"
ok "Registro de sensor OK"

VALID_EVENT_ID="$(uuid)"
VALID_TS="$(now_utc)"

VALID_EVENT_JSON="$(jq -n \
  --arg event_id "$VALID_EVENT_ID" \
  --arg tenant_id "$TENANT_A" \
  --arg sensor_id "$SENSOR_ID" \
  --arg ts "$VALID_TS" \
  '{
    schema_version: 1,
    event_id: $event_id,
    tenant_id: $tenant_id,
    sensor_id: $sensor_id,
    service: "http",
    src_ip: "203.0.113.25",
    src_port: 45678,
    timestamp_rfc3339: $ts,
    evidence: {
      username: null,
      ssh_auth_method: null,
      http_user_agent: "dm-e2e-t17/1.0",
      http_method: "GET",
      http_path: "/login"
    }
  }'
)"

RESP_BODY_FILE="$(mktemp)"
STATUS_FILE="$(mktemp)"

curl -sS \
  -o "$RESP_BODY_FILE" \
  -w "%{http_code}" \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$VALID_EVENT_JSON" > "$STATUS_FILE"

STATUS="$(cat "$STATUS_FILE")"
BODY="$(cat "$RESP_BODY_FILE")"

[ "$STATUS" = "201" ] || {
  echo "$BODY" >&2
  die "T17: esperaba 201 en evento válido, got $STATUS"
}

echo "$BODY" | jq . >/dev/null
ok "Evento válido responde 201"

SCHEMA_PERSISTED="$(docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -t -A -c \
"SELECT count(*) FROM events WHERE id = '$VALID_EVENT_ID' AND schema_version = 1 AND raw_event->>'schema_version' = '1';" | tr -d '[:space:]')"

[ "$SCHEMA_PERSISTED" = "1" ] || die "T17: schema_version no quedó conservado en DB"
ok "schema_version persistido en columna y raw_event"

MISSING_FIELD_JSON="$(jq -n \
  --arg event_id "$(uuid)" \
  --arg tenant_id "$TENANT_A" \
  --arg sensor_id "$SENSOR_ID" \
  --arg ts "$(now_utc)" \
  '{
    schema_version: 1,
    event_id: $event_id,
    tenant_id: $tenant_id,
    sensor_id: $sensor_id,
    service: "http",
    src_ip: "203.0.113.30",
    src_port: 55555,
    timestamp_rfc3339: $ts
  }'
)"

MISSING_FIELD_CODE="$(http_code -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$MISSING_FIELD_JSON")"

[ "$MISSING_FIELD_CODE" = "400" ] || die "T17: falta de campo obligatorio debía 400, got $MISSING_FIELD_CODE"
ok "Falta de campo obligatorio => 400"

BAD_SCHEMA_JSON="$(jq -n \
  --arg event_id "$(uuid)" \
  --arg tenant_id "$TENANT_A" \
  --arg sensor_id "$SENSOR_ID" \
  --arg ts "$(now_utc)" \
  '{
    schema_version: 2,
    event_id: $event_id,
    tenant_id: $tenant_id,
    sensor_id: $sensor_id,
    service: "http",
    src_ip: "203.0.113.40",
    src_port: 55556,
    timestamp_rfc3339: $ts,
    evidence: {
      username: null,
      ssh_auth_method: null,
      http_user_agent: "dm-bad-schema/1.0",
      http_method: "GET",
      http_path: "/login"
    }
  }'
)"

BAD_SCHEMA_CODE="$(http_code -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BAD_SCHEMA_JSON")"

[ "$BAD_SCHEMA_CODE" = "400" ] || die "T17: schema_version no soportado debía 400, got $BAD_SCHEMA_CODE"
ok "schema_version no soportado => 400"

test -f ./target/debug/sensor_agent || cargo build -p sensor_agent >/dev/null

T17_TMP_CFG="$(mktemp /tmp/dm_t17_XXXX.toml)"
T17_LOG_FILE="$(mktemp /tmp/dm_t17_XXXX.log)"

prepare_sensor_cfg \
  "$T17_TMP_CFG" \
  "$TENANT_A" \
  "$SENSOR_ID" \
  "$SENSOR_TOKEN" \
  "$API" \
  "60" \
  "127.0.0.1:$T12_SSH_PORT" \
  "127.0.0.1:$T13_HTTP_PORT"

info "Levantando sensor_agent para validar T12/T13 -> EventV1..."
if [ "$HAVE_STDBUF" = "1" ]; then
  stdbuf -oL -eL ./target/debug/sensor_agent --config "$T17_TMP_CFG" >"$T17_LOG_FILE" 2>&1 &
else
  ./target/debug/sensor_agent --config "$T17_TMP_CFG" >"$T17_LOG_FILE" 2>&1 &
fi
T17_AGENT_PID=$!

wait_for_log "ssh honeypot listening" "$T17_LOG_FILE" 20 || {
  cat "$T17_LOG_FILE" >&2
  die "T17: honeypot SSH no quedó escuchando"
}

wait_for_log "http honeypot listening" "$T17_LOG_FILE" 20 || {
  cat "$T17_LOG_FILE" >&2
  die "T17: honeypot HTTP no quedó escuchando"
}

ok "Sensor agent OK (SSH + HTTP activos)"

set +e
timeout 8s ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  -o PreferredAuthentications=none \
  -o PubkeyAuthentication=no \
  -o PasswordAuthentication=no \
  -o NumberOfPasswordPrompts=0 \
  -p "$T12_SSH_PORT" \
  "$T12_SSH_USER@127.0.0.1" true >/dev/null 2>&1
SSH_EC=$?
set -e

if [ "$SSH_EC" = "0" ]; then
  cat "$T17_LOG_FILE" >&2
  die "T17: el honeypot SSH no debía entregar shell"
fi

curl -sS -o /dev/null -A "$T13_HTTP_USER_AGENT" \
  "http://127.0.0.1:$T13_HTTP_PORT/login"

SSH_OK=0
HTTP_OK=0

for _ in $(seq 1 15); do
  SSH_COUNT="$(docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -t -A -c \
  "SELECT count(*) FROM events
   WHERE tenant_id = '$TENANT_A'
     AND sensor_id = '$SENSOR_ID'
     AND service = 'ssh'
     AND schema_version = 1
     AND raw_event->>'schema_version' = '1'
     AND COALESCE(raw_event->'evidence'->>'username','') <> ''
     AND COALESCE(raw_event->'evidence'->>'ssh_auth_method','') <> '';" | tr -d '[:space:]')"

  HTTP_COUNT="$(docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -t -A -c \
  "SELECT count(*) FROM events
   WHERE tenant_id = '$TENANT_A'
     AND sensor_id = '$SENSOR_ID'
     AND service = 'http'
     AND schema_version = 1
     AND raw_event->>'schema_version' = '1'
     AND COALESCE(raw_event->'evidence'->>'http_method','') <> ''
     AND COALESCE(raw_event->'evidence'->>'http_path','') <> '';" | tr -d '[:space:]')"

  if [ "${SSH_COUNT:-0}" -ge 1 ]; then
    SSH_OK=1
  fi

  if [ "${HTTP_COUNT:-0}" -ge 1 ]; then
    HTTP_OK=1
  fi

  if [ "$SSH_OK" = "1" ] && [ "$HTTP_OK" = "1" ]; then
    break
  fi

  sleep 1
done

[ "$SSH_OK" = "1" ] || {
  cat "$T17_LOG_FILE" >&2
  die "T17: T12 no produjo un EventV1 compatible persistido"
}

[ "$HTTP_OK" = "1" ] || {
  cat "$T17_LOG_FILE" >&2
  die "T17: T13 no produjo un EventV1 compatible persistido"
}

ok "T12 produce EventV1 compatible"
ok "T13 produce EventV1 compatible"
ok "T17 COMPLETADO"