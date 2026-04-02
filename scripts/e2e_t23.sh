#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${API:-http://localhost:8080}"
DM_FORCE_BUILD="${DM_FORCE_BUILD:-1}"

MOCK_CONTAINER_NAME="${MOCK_CONTAINER_NAME:-deceptionmesh-webhook-mock}"
MOCK_ALIAS="${MOCK_ALIAS:-webhook-mock}"
MOCK_PORT="${MOCK_PORT:-18080}"

CAPTURE_DIR="${CAPTURE_DIR:-$REPO_ROOT/.tmp/e2e}"
CAPTURE_FILE="${CAPTURE_FILE:-$CAPTURE_DIR/deceptionmesh_t23_webhooks.jsonl}"

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

http_code() {
  curl -sS -o /dev/null -w "%{http_code}" "$@" || true
}

wait_for_http_200() {
  local url="$1"
  local name="$2"

  for _ in $(seq 1 30); do
    local code
    code="$(http_code "$url")"
    if [ "$code" = "200" ]; then
      ok "$name responde 200"
      return 0
    fi
    sleep 1
  done

  docker compose ps >&2 || true
  docker compose logs --no-color --tail 200 control_plane >&2 || true
  die "$name no respondió 200 a tiempo"
}

wait_for_file_nonempty() {
  local file="$1"
  local seconds="${2:-20}"

  for _ in $(seq 1 "$seconds"); do
    if [ -s "$file" ]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

need docker
need curl
need jq
need sed
need python3

mkdir -p "$CAPTURE_DIR"
rm -f "$CAPTURE_FILE"

cleanup() {
  docker rm -f "$MOCK_CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "API=$API"
if [ "$DM_FORCE_BUILD" = "1" ]; then
  info "Levantando stack con build forzado"
  docker compose up -d --build >/dev/null
else
  info "Levantando stack sin build forzado"
  docker compose up -d >/dev/null
fi

wait_for_http_200 "$API/health" "/health"
wait_for_http_200 "$API/ready" "/ready"
ok "Stack OK (/health y /ready)"

CONTROL_PLANE_CID="$(docker compose ps -q control_plane | tr -d '\r')"
[ -n "$CONTROL_PLANE_CID" ] || die "No pude detectar el contenedor de control_plane"

NETWORK_NAME="$(docker inspect "$CONTROL_PLANE_CID"   --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'   | head -n 1 | tr -d '\r')"

[ -n "$NETWORK_NAME" ] || die "No pude detectar la red Docker del control_plane"
ok "Red detectada: $NETWORK_NAME"

info "Levantando receptor webhook mock dentro de la red Docker"
docker rm -f "$MOCK_CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d --rm \
  --name "$MOCK_CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --network-alias "$MOCK_ALIAS" \
  -v "$REPO_ROOT/scripts/mock_webhook_receiver.py:/app/mock_webhook_receiver.py:ro" \
  -v "$CAPTURE_DIR:/captures" \
  python:3.12-alpine \
  python /app/mock_webhook_receiver.py "/captures/$(basename "$CAPTURE_FILE")" "$MOCK_PORT" >/dev/null

sleep 1

RUNNING="$(docker inspect -f '{{.State.Running}}' "$MOCK_CONTAINER_NAME" 2>/dev/null || true)"
[ "$RUNNING" = "true" ] || {
  docker logs "$MOCK_CONTAINER_NAME" >&2 || true
  die "No arrancó el receptor webhook mock"
}
ok "Webhook mock corriendo en red interna Docker"

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
  status="$(curl -sS -o /tmp/dm_t23_http_body.json -w "%{http_code}" \
    -X POST "$API/events/ingest" \
    -H "Authorization: Bearer $sensor_token" \
    -H "Content-Type: application/json" \
    -d "$event_json")"

  [ "$status" = "201" ] || {
    cat /tmp/dm_t23_http_body.json >&2
    die "Evento HTTP debía responder 201, got $status"
  }

  cat /tmp/dm_t23_http_body.json
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
  status="$(curl -sS -o /tmp/dm_t23_ssh_body.json -w "%{http_code}" \
    -X POST "$API/events/ingest" \
    -H "Authorization: Bearer $sensor_token" \
    -H "Content-Type: application/json" \
    -d "$event_json")"

  [ "$status" = "201" ] || {
    cat /tmp/dm_t23_ssh_body.json >&2
    die "Evento SSH decoy debía responder 201, got $status"
  }

  cat /tmp/dm_t23_ssh_body.json
}

TENANT_A="$(uuid)"
create_tenant_with_admin "$TENANT_A" "Tenant A T23"
ok "Tenant creado"

SENSOR_A_INFO="$(create_sensor "$TENANT_A" "sensor-a-t23")"
SENSOR_A_ID="$(echo "$SENSOR_A_INFO" | cut -d'|' -f1)"
SENSOR_A_TOKEN="$(echo "$SENSOR_A_INFO" | cut -d'|' -f2)"
ok "Sensor registrado"

WEBHOOK_CFG="$(curl -sS -X PUT "$API/v1/tenants/$TENANT_A/webhook" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"webhook_url\":\"http://$MOCK_ALIAS:$MOCK_PORT/hook\",\"webhook_min_severity\":3}")"

[ "$(echo "$WEBHOOK_CFG" | jq -r .tenant_id)" = "$TENANT_A" ] || die "No se configuró webhook para el tenant esperado"
[ "$(echo "$WEBHOOK_CFG" | jq -r .webhook_min_severity)" = "3" ] || die "El umbral de webhook no quedó en 3"
ok "Webhook configurado"

LOW_EVENT="$(post_http_event "$TENANT_A" "$SENSOR_A_ID" "$SENSOR_A_TOKEN" "203.0.113.50" 45678 "GET" "/login" "dm-t23-http-low")"
[ "$(echo "$LOW_EVENT" | jq -r .severity)" = "low" ] || die "El evento bajo debía quedar severity=low"

sleep 2
if [ -s "$CAPTURE_FILE" ]; then
  echo "Webhook capturado inesperadamente:" >&2
  cat "$CAPTURE_FILE" >&2
  die "Un evento low no debería disparar el webhook con umbral=3"
fi
ok "Umbral respetado: low no dispara webhook"

CRITICAL_EVENT="$(post_ssh_decoy_event "$TENANT_A" "$SENSOR_A_ID" "$SENSOR_A_TOKEN" "203.0.113.77" 2222 "decoy-admin")"
CRITICAL_ID="$(echo "$CRITICAL_EVENT" | jq -r .event_id)"
[ "$(echo "$CRITICAL_EVENT" | jq -r .severity)" = "critical" ] || die "El evento decoy credential debía quedar severity=critical"

wait_for_file_nonempty "$CAPTURE_FILE" 20 || {
  docker logs "$MOCK_CONTAINER_NAME" >&2 || true
  docker compose logs --no-color --tail 200 control_plane >&2 || true
  die "No llegó ningún webhook al receptor mock"
}

PAYLOAD="$(tail -n 1 "$CAPTURE_FILE")"

[ "$(echo "$PAYLOAD" | jq -r .version)" = "deception_mesh.event.v1" ] || die "Payload webhook sin version esperada"
[ "$(echo "$PAYLOAD" | jq -r .tenant.id)" = "$TENANT_A" ] || die "tenant.id incorrecto en webhook"
[ "$(echo "$PAYLOAD" | jq -r .sensor.id)" = "$SENSOR_A_ID" ] || die "sensor.id incorrecto en webhook"
[ "$(echo "$PAYLOAD" | jq -r .event.id)" = "$CRITICAL_ID" ] || die "event.id incorrecto en webhook"
[ "$(echo "$PAYLOAD" | jq -r .event.severity)" = "critical" ] || die "severity incorrecta en webhook"
[ "$(echo "$PAYLOAD" | jq -r .event.service)" = "ssh" ] || die "service incorrecto en webhook"
[ "$(echo "$PAYLOAD" | jq -r .event.evidence.decoy_kind)" = "credential" ] || die "evidence.decoy_kind incorrecto"
[ "$(echo "$PAYLOAD" | jq -r .event.evidence.username)" = "decoy-admin" ] || die "username incorrecto en webhook"

ok "Webhook recibido con payload esperado"
ok "T23 COMPLETADO"