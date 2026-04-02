#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${API:-http://localhost:8080}"

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

need docker
need curl
need jq
need sed

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
"INSERT INTO tenants (id, name) VALUES ('$TENANT_A','Acme T18') ON CONFLICT DO NOTHING;" >/dev/null

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
  -d "{\"tenant_id\":\"$TENANT_A\",\"enroll_token\":\"$ENROLL_TOKEN\",\"name\":\"sensor-t18\"}")"

SENSOR_ID="$(echo "$REGISTER_JSON" | jq -r .sensor_id)"
SENSOR_TOKEN="$(echo "$REGISTER_JSON" | jq -r .sensor_token)"

[ -n "$SENSOR_ID" ] && [ "$SENSOR_ID" != "null" ] || die "No se obtuvo sensor_id"
[ -n "$SENSOR_TOKEN" ] && [ "$SENSOR_TOKEN" != "null" ] || die "No se obtuvo sensor_token"
ok "Registro de sensor OK"

post_http_event() {
  local src_ip="$1"
  local src_port="$2"
  local method="$3"
  local path="$4"

  local event_json
  event_json="$(jq -n \
    --arg event_id "$(uuid)" \
    --arg tenant_id "$TENANT_A" \
    --arg sensor_id "$SENSOR_ID" \
    --arg ts "$(now_utc)" \
    --arg src_ip "$src_ip" \
    --arg method "$method" \
    --arg path "$path" \
    --argjson src_port "$src_port" \
    '{
      schema_version: 1,
      event_id: $event_id,
      tenant_id: $tenant_id,
      sensor_id: $sensor_id,
      service: "http",
      src_ip: $src_ip,
      src_port: $src_port,
      timestamp_rfc3339: $ts,
      evidence: {
        username: null,
        ssh_auth_method: null,
        http_user_agent: "dm-e2e-t18-http/1.0",
        http_method: $method,
        http_path: $path,
        decoy_hit: false,
        decoy_kind: null
      }
    }'
  )"

  local body_file status_file
  body_file="$(mktemp)"
  status_file="$(mktemp)"

  curl -sS \
    -o "$body_file" \
    -w "%{http_code}" \
    -X POST "$API/events/ingest" \
    -H "Authorization: Bearer $SENSOR_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$event_json" > "$status_file"

  local status body
  status="$(cat "$status_file")"
  body="$(cat "$body_file")"

  rm -f "$body_file" "$status_file"

  [ "$status" = "201" ] || {
    echo "$body" >&2
    die "Evento HTTP válido debía responder 201, got $status"
  }

  echo "$body"
}

post_ssh_decoy_event() {
  local src_ip="$1"
  local src_port="$2"

  local event_json
  event_json="$(jq -n \
    --arg event_id "$(uuid)" \
    --arg tenant_id "$TENANT_A" \
    --arg sensor_id "$SENSOR_ID" \
    --arg ts "$(now_utc)" \
    --arg src_ip "$src_ip" \
    --argjson src_port "$src_port" \
    '{
      schema_version: 1,
      event_id: $event_id,
      tenant_id: $tenant_id,
      sensor_id: $sensor_id,
      service: "ssh",
      src_ip: $src_ip,
      src_port: $src_port,
      timestamp_rfc3339: $ts,
      evidence: {
        username: "decoy-admin",
        ssh_auth_method: "password",
        http_user_agent: null,
        http_method: null,
        http_path: null,
        decoy_hit: true,
        decoy_kind: "credential"
      }
    }'
  )"

  local body_file status_file
  body_file="$(mktemp)"
  status_file="$(mktemp)"

  curl -sS \
    -o "$body_file" \
    -w "%{http_code}" \
    -X POST "$API/events/ingest" \
    -H "Authorization: Bearer $SENSOR_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$event_json" > "$status_file"

  local status body
  status="$(cat "$status_file")"
  body="$(cat "$body_file")"

  rm -f "$body_file" "$status_file"

  [ "$status" = "201" ] || {
    echo "$body" >&2
    die "Evento SSH decoy válido debía responder 201, got $status"
  }

  echo "$body"
}

REPEAT_IP="203.0.113.88"
LAST_BODY=""
LAST_EVENT_ID=""
LAST_SEVERITY=""
LAST_ATTEMPTS=""

for i in $(seq 1 10); do
  LAST_BODY="$(post_http_event "$REPEAT_IP" 45678 "GET" "/login")"
  LAST_EVENT_ID="$(echo "$LAST_BODY" | jq -r .event_id)"
  LAST_SEVERITY="$(echo "$LAST_BODY" | jq -r .severity)"
  LAST_ATTEMPTS="$(echo "$LAST_BODY" | jq -r .attempt_count)"

  case "$i" in
    1)
      [ "$LAST_SEVERITY" = "low" ] || die "Intento 1 debía ser low, got $LAST_SEVERITY"
      [ "$LAST_ATTEMPTS" = "1" ] || die "Intento 1 debía marcar attempt_count=1, got $LAST_ATTEMPTS"
      ok "1 intento => low"
      ;;
    3)
      [ "$LAST_SEVERITY" = "medium" ] || die "Intento 3 debía ser medium, got $LAST_SEVERITY"
      [ "$LAST_ATTEMPTS" = "3" ] || die "Intento 3 debía marcar attempt_count=3, got $LAST_ATTEMPTS"
      ok "3 intentos => medium"
      ;;
    5)
      [ "$LAST_SEVERITY" = "high" ] || die "Intento 5 debía ser high, got $LAST_SEVERITY"
      [ "$LAST_ATTEMPTS" = "5" ] || die "Intento 5 debía marcar attempt_count=5, got $LAST_ATTEMPTS"
      ok "5 intentos => high"
      ;;
    10)
      [ "$LAST_SEVERITY" = "critical" ] || die "Intento 10 debía ser critical, got $LAST_SEVERITY"
      [ "$LAST_ATTEMPTS" = "10" ] || die "Intento 10 debía marcar attempt_count=10, got $LAST_ATTEMPTS"
      ok "10 intentos => critical"
      ;;
  esac
done

DB_REPEAT="$(docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -t -A -F '|' -c \
"SELECT severity, attempt_count, severity_reason
 FROM events
 WHERE id = '$LAST_EVENT_ID';" | tr -d '[:space:]')"

[ "$DB_REPEAT" = "critical|10|repeat_threshold_critical" ] || {
  echo "$DB_REPEAT" >&2
  die "Persistencia DB de repetición no coincide"
}
ok "Persistencia DB OK para repetición"

DECOY_BODY="$(post_ssh_decoy_event "203.0.113.99" 54321)"
DECOY_EVENT_ID="$(echo "$DECOY_BODY" | jq -r .event_id)"
DECOY_SEVERITY="$(echo "$DECOY_BODY" | jq -r .severity)"

case "$DECOY_SEVERITY" in
  high|critical) ;;
  *) die "Credencial decoy debía ser high o critical, got $DECOY_SEVERITY" ;;
esac
ok "Credencial decoy => $DECOY_SEVERITY"

DECOY_REASON="$(docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -t -A -c \
"SELECT severity_reason FROM events WHERE id = '$DECOY_EVENT_ID';" | tr -d '[:space:]')"

echo "$DECOY_REASON" | grep -q "decoy_credential_hit" || die "severity_reason no marcó decoy_credential_hit"
ok "Persistencia DB OK para decoy"

ok "T18 COMPLETADO"