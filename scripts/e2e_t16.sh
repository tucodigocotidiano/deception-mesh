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

TENANT_A="$(uuid)"
docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"INSERT INTO tenants (id, name) VALUES ('$TENANT_A','Acme T16') ON CONFLICT DO NOTHING;" >/dev/null

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
  -d "{\"tenant_id\":\"$TENANT_A\",\"enroll_token\":\"$ENROLL_TOKEN\",\"name\":\"sensor-t16\"}")"

SENSOR_ID="$(echo "$REGISTER_JSON" | jq -r .sensor_id)"
SENSOR_TOKEN="$(echo "$REGISTER_JSON" | jq -r .sensor_token)"
[ -n "$SENSOR_ID" ] && [ "$SENSOR_ID" != "null" ] || die "No se obtuvo sensor_id"
[ -n "$SENSOR_TOKEN" ] && [ "$SENSOR_TOKEN" != "null" ] || die "No se obtuvo sensor_token"

EVENT_ID="$(uuid)"
TS="$(now_utc)"

EVENT_JSON="$(jq -n \
  --arg event_id "$EVENT_ID" \
  --arg tenant_id "$TENANT_A" \
  --arg sensor_id "$SENSOR_ID" \
  --arg ts "$TS" \
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
      http_user_agent: "dm-e2e-t16/1.0",
      http_method: "GET",
      http_path: "/login"
    }
  }'
)"

RESP_BODY_FILE="$(mktemp)"
STATUS_FILE="$(mktemp)"
trap 'rm -f "$RESP_BODY_FILE" "$STATUS_FILE"' EXIT

curl -sS \
  -o "$RESP_BODY_FILE" \
  -w "%{http_code}" \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$EVENT_JSON" > "$STATUS_FILE"

STATUS="$(cat "$STATUS_FILE")"
BODY="$(cat "$RESP_BODY_FILE")"

[ "$STATUS" = "201" ] || {
  echo "$BODY" >&2
  die "T16: esperaba 201 en ingest, got $STATUS"
}

echo "$BODY" | jq . >/dev/null
ok "T16 ingest responde 201"

COUNT="$(docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -t -A -c \
"SELECT count(*) FROM events WHERE id = '$EVENT_ID';" | tr -d '[:space:]')"

[ "$COUNT" = "1" ] || die "T16: el evento no quedó en DB"
ok "T16 OK (evento persistido en events)"

BAD_PAYLOAD_CODE="$(http_code -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"schema_version":1}')"

[ "$BAD_PAYLOAD_CODE" = "400" ] || die "T16: payload inválido debía 400, got $BAD_PAYLOAD_CODE"
ok "T16 OK (payload inválido => 400)"

BAD_TOKEN_CODE="$(http_code -X POST "$API/events/ingest" \
  -H "Authorization: Bearer dm_sensor_fake" \
  -H "Content-Type: application/json" \
  -d "$EVENT_JSON")"

[ "$BAD_TOKEN_CODE" = "401" ] || die "T16: token inválido debía 401, got $BAD_TOKEN_CODE"
ok "T16 OK (token inválido => 401)"

ok "T16 COMPLETADO"