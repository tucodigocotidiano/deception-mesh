#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${API:-http://localhost:8080}"
DM_FORCE_BUILD="${DM_FORCE_BUILD:-1}"
MOCK_CONTAINER_NAME="${MOCK_CONTAINER_NAME:-deceptionmesh-webhook-flaky}"
MOCK_ALIAS="${MOCK_ALIAS:-webhook-flaky}"
MOCK_PORT="${MOCK_PORT:-18081}"
FAIL_FIRST="${FAIL_FIRST:-3}"
CAPTURE_DIR="${CAPTURE_DIR:-$REPO_ROOT/.tmp/e2e}"
CAPTURE_FILE="${CAPTURE_FILE:-$CAPTURE_DIR/deceptionmesh_t24_webhooks.jsonl}"

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

wait_for_mock_ready() {
  local container="$1"
  local port="$2"

  for _ in $(seq 1 30); do
    if docker exec "$container" python - "$port" <<'PY' >/dev/null 2>&1
import json
import sys
import urllib.request

port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as resp:
    payload = json.loads(resp.read().decode())
    raise SystemExit(0 if payload.get("ok") is True else 1)
PY
    then
      ok "Webhook flaky mock listo"
      return 0
    fi
    sleep 1
  done

  docker logs "$container" >&2 || true
  die "Webhook flaky mock no quedó listo"
}

need docker
need curl
need jq
need python3
need sed

mkdir -p "$CAPTURE_DIR"
rm -f "$CAPTURE_FILE" "$CAPTURE_FILE.state.json"

cleanup() {
  docker rm -f "$MOCK_CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "$DM_FORCE_BUILD" = "1" ]; then
  docker compose up -d --build >/dev/null
else
  docker compose up -d >/dev/null
fi

wait_for_http_200 "$API/health" "/health"
wait_for_http_200 "$API/ready" "/ready"

CONTROL_PLANE_CID="$(docker compose ps -q control_plane | tr -d '\r')"
[ -n "$CONTROL_PLANE_CID" ] || die "No pude detectar el contenedor de control_plane"

NETWORK_NAME="$(docker inspect "$CONTROL_PLANE_CID"   --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}'   | head -n 1 | tr -d '\r')"

[ -n "$NETWORK_NAME" ] || die "No pude detectar la red Docker del control_plane"

info "Levantando receptor webhook flaky dentro de la red Docker"
docker rm -f "$MOCK_CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d --rm \
  --name "$MOCK_CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --network-alias "$MOCK_ALIAS" \
  -v "$REPO_ROOT/scripts/mock_webhook_flaky_receiver.py:/app/mock_webhook_flaky_receiver.py:ro" \
  -v "$CAPTURE_DIR:/captures" \
  python:3.12-alpine \
  python /app/mock_webhook_flaky_receiver.py "/captures/$(basename "$CAPTURE_FILE")" "$MOCK_PORT" "$FAIL_FIRST" >/dev/null

wait_for_mock_ready "$MOCK_CONTAINER_NAME" "$MOCK_PORT"

LOGIN_JSON="$(curl -sS -X POST "$API/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@acme.com","password":"admin"}')"

TOKEN="$(echo "$LOGIN_JSON" | jq -r .access_token)"
USER_ID="$(echo "$LOGIN_JSON" | jq -r .user_id)"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || die "No se obtuvo access_token"
[ -n "$USER_ID" ] && [ "$USER_ID" != "null" ] || die "No se obtuvo user_id"

DB_URL="$(docker compose exec -T control_plane printenv DATABASE_URL | tr -d '\r')"
DB_NAME="$(echo "$DB_URL" | sed -E 's#.*/##')"
PGUSER="$(docker compose exec -T postgres printenv POSTGRES_USER | tr -d '\r')"

TENANT_ID="$(uuid)"

docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
  "INSERT INTO tenants (id, name) VALUES ('$TENANT_ID','Tenant T24') ON CONFLICT DO NOTHING;" >/dev/null

docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
  "INSERT INTO memberships (tenant_id, user_id, role) VALUES ('$TENANT_ID','$USER_ID','admin') ON CONFLICT DO NOTHING;" >/dev/null

ENROLL_JSON="$(curl -sS -X POST "$API/v1/tenants/$TENANT_ID/sensors/enroll-token" \
  -H "Authorization: Bearer $TOKEN")"
ENROLL_TOKEN="$(echo "$ENROLL_JSON" | jq -r .enroll_token)"
[ -n "$ENROLL_TOKEN" ] && [ "$ENROLL_TOKEN" != "null" ] || die "No se obtuvo enroll_token"

REGISTER_JSON="$(curl -sS -X POST "$API/sensors/register" \
  -H "Content-Type: application/json" \
  -d "{\"tenant_id\":\"$TENANT_ID\",\"enroll_token\":\"$ENROLL_TOKEN\",\"name\":\"sensor-t24\"}")"

SENSOR_ID="$(echo "$REGISTER_JSON" | jq -r .sensor_id)"
SENSOR_TOKEN="$(echo "$REGISTER_JSON" | jq -r .sensor_token)"
[ -n "$SENSOR_ID" ] && [ "$SENSOR_ID" != "null" ] || die "No se obtuvo sensor_id"
[ -n "$SENSOR_TOKEN" ] && [ "$SENSOR_TOKEN" != "null" ] || die "No se obtuvo sensor_token"

WEBHOOK_CFG="$(curl -sS -X PUT "$API/v1/tenants/$TENANT_ID/webhook" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"webhook_url\":\"http://$MOCK_ALIAS:$MOCK_PORT/hook\",\"webhook_min_severity\":3}")"

[ "$(echo "$WEBHOOK_CFG" | jq -r .tenant_id)" = "$TENANT_ID" ] || die "No se configuró el webhook"
[ "$(echo "$WEBHOOK_CFG" | jq -r .webhook_min_severity)" = "3" ] || die "El umbral del webhook no quedó en 3"

EVENT_ID="$(uuid)"
EVENT_JSON="$(jq -n \
  --arg event_id "$EVENT_ID" \
  --arg tenant_id "$TENANT_ID" \
  --arg sensor_id "$SENSOR_ID" \
  --arg ts "$(now_utc)" \
  --arg src_ip "203.0.113.77" \
  '{
    schema_version: 1,
    event_id: $event_id,
    tenant_id: $tenant_id,
    sensor_id: $sensor_id,
    service: "ssh",
    src_ip: $src_ip,
    src_port: 2222,
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
  }')"

INGEST_JSON="$(curl -sS -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$EVENT_JSON")"

DELIVERY_ID="$(echo "$INGEST_JSON" | jq -r .webhook_delivery_id)"
[ -n "$DELIVERY_ID" ] && [ "$DELIVERY_ID" != "null" ] || die "No se obtuvo webhook_delivery_id"

ok "Entrega webhook encolada: $DELIVERY_ID"

MIN_EXPECTED_ATTEMPTS=$((FAIL_FIRST + 1))

for _ in $(seq 1 45); do
  DELIVERIES="$(curl -sS \
    "$API/v1/tenants/$TENANT_ID/webhook-deliveries?event_id=$EVENT_ID" \
    -H "Authorization: Bearer $TOKEN")"

  STATUS="$(echo "$DELIVERIES" | jq -r '.[0].status // empty')"
  ATTEMPTS="$(echo "$DELIVERIES" | jq -r '.[0].attempt_count // 0')"
  FAILED_ATTEMPTS="$(echo "$DELIVERIES" | jq -r '[.[0].attempts[]? | select(.success == false)] | length')"
  SUCCESS_ATTEMPTS="$(echo "$DELIVERIES" | jq -r '[.[0].attempts[]? | select(.success == true)] | length')"
  ERRORS_VISIBLE="$(echo "$DELIVERIES" | jq -r '[.[0].attempts[]? | select(.success == false) | select((.error_message != null and .error_message != "") or (.http_status != null))] | length')"

  if [ "$STATUS" = "delivered" ] \
    && [ "$ATTEMPTS" -ge "$MIN_EXPECTED_ATTEMPTS" ] \
    && [ "$FAILED_ATTEMPTS" -ge "$FAIL_FIRST" ] \
    && [ "$SUCCESS_ATTEMPTS" -ge 1 ] \
    && [ "$ERRORS_VISIBLE" -ge "$FAIL_FIRST" ]; then
    ok "Webhook terminó entregado tras reintentos"
    ok "Historial visible de intentos y errores confirmado"
    echo "$DELIVERIES" | jq .
    exit 0
  fi

  sleep 2
done

docker compose logs --no-color --tail 200 control_plane >&2 || true
docker logs "$MOCK_CONTAINER_NAME" >&2 || true
die "No se observó delivery=delivered con historial visible suficiente"