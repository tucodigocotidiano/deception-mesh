#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${API:-http://localhost:8080}"
DM_FORCE_BUILD="${DM_FORCE_BUILD:-0}"

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

past_utc() {
  date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

future_utc() {
  date -u -d '1 hour' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

http_code() { curl -sS -o /dev/null -w "%{http_code}" "$@"; }

need docker
need curl
need jq
need sed

info "API=$API"

if [ "$DM_FORCE_BUILD" = "1" ]; then
  info "Levantando stack con build forzado"
  docker compose up -d --build >/dev/null
else
  info "Levantando stack sin build forzado"
  docker compose up -d >/dev/null
fi

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

create_tenant_with_admin() {
  local tenant_id="$1"
  local tenant_name="$2"

  docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
  "INSERT INTO tenants (id, name) VALUES ('$tenant_id','$tenant_name') ON CONFLICT DO NOTHING;" >/dev/null

  docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
  "INSERT INTO memberships (tenant_id, user_id, role)
   VALUES ('$tenant_id','$USER_ID','admin')
   ON CONFLICT DO NOTHING;" >/dev/null
}

create_sensor() {
  local tenant_id="$1"
  local sensor_name="$2"

  local enroll_json enroll_token register_json sensor_id sensor_token
  enroll_json="$(curl -sS -X POST "$API/v1/tenants/$tenant_id/sensors/enroll-token" \
    -H "Authorization: Bearer $TOKEN")"

  enroll_token="$(echo "$enroll_json" | jq -r .enroll_token)"
  [ -n "$enroll_token" ] && [ "$enroll_token" != "null" ] || die "No se obtuvo enroll_token"

  register_json="$(curl -sS -X POST "$API/sensors/register" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"$tenant_id\",\"enroll_token\":\"$enroll_token\",\"name\":\"$sensor_name\"}")"

  sensor_id="$(echo "$register_json" | jq -r .sensor_id)"
  sensor_token="$(echo "$register_json" | jq -r .sensor_token)"

  [ -n "$sensor_id" ] && [ "$sensor_id" != "null" ] || die "No se obtuvo sensor_id"
  [ -n "$sensor_token" ] && [ "$sensor_token" != "null" ] || die "No se obtuvo sensor_token"

  echo "$sensor_id|$sensor_token"
}

post_http_event() {
  local tenant_id="$1"
  local sensor_id="$2"
  local sensor_token="$3"
  local src_ip="$4"
  local src_port="$5"
  local method="$6"
  local path="$7"
  local ua="$8"

  local event_json
  event_json="$(jq -n \
    --arg event_id "$(uuid)" \
    --arg tenant_id "$tenant_id" \
    --arg sensor_id "$sensor_id" \
    --arg ts "$(now_utc)" \
    --arg src_ip "$src_ip" \
    --arg method "$method" \
    --arg path "$path" \
    --arg ua "$ua" \
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
        http_user_agent: $ua,
        http_method: $method,
        http_path: $path,
        decoy_hit: false,
        decoy_kind: null
      }
    }'
  )"

  local status
  status="$(curl -sS -o /tmp/dm_t20_http_body.json -w "%{http_code}" \
    -X POST "$API/events/ingest" \
    -H "Authorization: Bearer $sensor_token" \
    -H "Content-Type: application/json" \
    -d "$event_json")"

  [ "$status" = "201" ] || {
    cat /tmp/dm_t20_http_body.json >&2
    die "Evento HTTP debía responder 201, got $status"
  }

  cat /tmp/dm_t20_http_body.json
}

post_ssh_decoy_event() {
  local tenant_id="$1"
  local sensor_id="$2"
  local sensor_token="$3"
  local src_ip="$4"
  local src_port="$5"
  local username="$6"

  local event_json
  event_json="$(jq -n \
    --arg event_id "$(uuid)" \
    --arg tenant_id "$tenant_id" \
    --arg sensor_id "$sensor_id" \
    --arg ts "$(now_utc)" \
    --arg src_ip "$src_ip" \
    --arg username "$username" \
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
        username: $username,
        ssh_auth_method: "password",
        http_user_agent: null,
        http_method: null,
        http_path: null,
        decoy_hit: true,
        decoy_kind: "credential"
      }
    }'
  )"

  local status
  status="$(curl -sS -o /tmp/dm_t20_ssh_body.json -w "%{http_code}" \
    -X POST "$API/events/ingest" \
    -H "Authorization: Bearer $sensor_token" \
    -H "Content-Type: application/json" \
    -d "$event_json")"

  [ "$status" = "201" ] || {
    cat /tmp/dm_t20_ssh_body.json >&2
    die "Evento SSH decoy debía responder 201, got $status"
  }

  cat /tmp/dm_t20_ssh_body.json
}

TENANT_A="$(uuid)"
TENANT_B="$(uuid)"

create_tenant_with_admin "$TENANT_A" "Tenant A T20"
create_tenant_with_admin "$TENANT_B" "Tenant B T20"
ok "Tenants creados"

SENSOR_A_INFO="$(create_sensor "$TENANT_A" "sensor-a-t20")"
SENSOR_B_INFO="$(create_sensor "$TENANT_B" "sensor-b-t20")"

SENSOR_A_ID="$(echo "$SENSOR_A_INFO" | cut -d'|' -f1)"
SENSOR_A_TOKEN="$(echo "$SENSOR_A_INFO" | cut -d'|' -f2)"
SENSOR_B_ID="$(echo "$SENSOR_B_INFO" | cut -d'|' -f1)"
SENSOR_B_TOKEN="$(echo "$SENSOR_B_INFO" | cut -d'|' -f2)"

ok "Sensores registrados"

HTTP_A1="$(post_http_event "$TENANT_A" "$SENSOR_A_ID" "$SENSOR_A_TOKEN" "203.0.113.10" 45678 "GET" "/login" "dm-t20-http-a1")"
HTTP_A2="$(post_http_event "$TENANT_A" "$SENSOR_A_ID" "$SENSOR_A_TOKEN" "203.0.113.10" 45679 "POST" "/wp-login.php" "dm-t20-http-a2")"
SSH_A="$(post_ssh_decoy_event "$TENANT_A" "$SENSOR_A_ID" "$SENSOR_A_TOKEN" "203.0.113.11" 2222 "decoy-admin")"
HTTP_B="$(post_http_event "$TENANT_B" "$SENSOR_B_ID" "$SENSOR_B_TOKEN" "198.51.100.20" 40000 "GET" "/admin" "dm-t20-http-b1")"

A_CRITICAL_ID="$(echo "$SSH_A" | jq -r .event_id)"
B_EVENT_ID="$(echo "$HTTP_B" | jq -r .event_id)"

ok "Eventos sembrados para T20"

PAGE1="$(curl -sS "$API/events?tenant_id=$TENANT_A&limit=2&page=1" \
  -H "Authorization: Bearer $TOKEN")"

[ "$(echo "$PAGE1" | jq -r .tenant_id)" = "$TENANT_A" ] || die "tenant_id en respuesta no coincide"
[ "$(echo "$PAGE1" | jq -r .returned)" = "2" ] || die "page=1 debía devolver 2 items"
[ "$(echo "$PAGE1" | jq -r .has_more)" = "true" ] || die "page=1 debía tener has_more=true"
[ "$(echo "$PAGE1" | jq -r .next_page)" = "2" ] || die "page=1 debía anunciar next_page=2"
ok "Paginación page=1 OK"

PAGE2="$(curl -sS "$API/events?tenant_id=$TENANT_A&limit=2&page=2" \
  -H "Authorization: Bearer $TOKEN")"

[ "$(echo "$PAGE2" | jq -r .returned)" = "1" ] || die "page=2 debía devolver 1 item"
[ "$(echo "$PAGE2" | jq -r .has_more)" = "false" ] || die "page=2 debía tener has_more=false"
ok "Paginación page=2 OK"

TENANT_A_IDS="$(echo "$PAGE1" | jq -r '.items[].id')"$'\n'"$(echo "$PAGE2" | jq -r '.items[].id')"
echo "$TENANT_A_IDS" | grep -q "$B_EVENT_ID" && die "Tenant A no debería ver evento de Tenant B"
ok "Aislamiento entre tenants OK"

BY_SERVICE="$(curl -sS "$API/events?tenant_id=$TENANT_A&service=http&limit=10&page=1" \
  -H "Authorization: Bearer $TOKEN")"
[ "$(echo "$BY_SERVICE" | jq -r '.items | length')" = "2" ] || die "Filtro service=http debía devolver 2 eventos"
[ "$(echo "$BY_SERVICE" | jq -r '[.items[].service] | unique | join(",")')" = "http" ] || die "Filtro service no aisló http"
ok "Filtro service OK"

BY_SEVERITY="$(curl -sS "$API/events?tenant_id=$TENANT_A&severity=critical&limit=10&page=1" \
  -H "Authorization: Bearer $TOKEN")"
[ "$(echo "$BY_SEVERITY" | jq -r '.items | length')" = "1" ] || die "Filtro severity=critical debía devolver 1 evento"
[ "$(echo "$BY_SEVERITY" | jq -r '.items[0].id')" = "$A_CRITICAL_ID" ] || die "Filtro severity no devolvió el evento crítico esperado"
ok "Filtro severity OK"

BY_SENSOR="$(curl -sS "$API/events?tenant_id=$TENANT_A&sensor_id=$SENSOR_A_ID&limit=10&page=1" \
  -H "Authorization: Bearer $TOKEN")"
[ "$(echo "$BY_SENSOR" | jq -r '.items | length')" = "3" ] || die "Filtro sensor_id debía devolver 3 eventos"
ok "Filtro sensor OK"

BY_IP="$(curl -sS "$API/events?tenant_id=$TENANT_A&src_ip=203.0.113.10&limit=10&page=1" \
  -H "Authorization: Bearer $TOKEN")"
[ "$(echo "$BY_IP" | jq -r '.items | length')" = "2" ] || die "Filtro src_ip debía devolver 2 eventos"
ok "Filtro IP OK"

BY_TEXT="$(curl -sS "$API/events?tenant_id=$TENANT_A&text=wp-login.php&limit=10&page=1" \
  -H "Authorization: Bearer $TOKEN")"
[ "$(echo "$BY_TEXT" | jq -r '.items | length')" = "1" ] || die "Filtro text debía devolver 1 evento"
[ "$(echo "$BY_TEXT" | jq -r '.items[0].raw_event.evidence.http_path')" = "/wp-login.php" ] || die "Filtro text no encontró el evento esperado"
ok "Filtro texto OK"

START_TS="$(past_utc)"
END_TS="$(future_utc)"
BY_DATE="$(curl -sS "$API/events?tenant_id=$TENANT_A&start=$START_TS&end=$END_TS&limit=10&page=1" \
  -H "Authorization: Bearer $TOKEN")"
[ "$(echo "$BY_DATE" | jq -r '.items | length')" = "3" ] || die "Filtro fecha debía devolver 3 eventos"
ok "Filtro fecha OK"

SCOPED_ROUTE="$(curl -sS "$API/v1/tenants/$TENANT_A/events?limit=10&page=1" \
  -H "Authorization: Bearer $TOKEN")"
[ "$(echo "$SCOPED_ROUTE" | jq -r '.items | length')" = "3" ] || die "Ruta /v1/tenants/:tenant_id/events debía devolver 3 eventos"
ok "Ruta tenant-scoped OK"

ok "T20 COMPLETADO"