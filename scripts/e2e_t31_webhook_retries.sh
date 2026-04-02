#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_lib.sh"

require_base_deps
ensure_stack
wait_for_http_200 "$API/health" "/health"
wait_for_http_200 "$API/ready" "/ready"

TMP_DIR="$(mktemp -d /tmp/deceptionmesh_t31_webhook.XXXXXX)"
FLAKY_CAPTURE_FILE="$TMP_DIR/flaky_webhooks.jsonl"
FLAKY_LOG="$TMP_DIR/flaky_webhook.log"
FLAKY_PORT="${FLAKY_PORT:-18081}"
FLAKY_FAIL_FIRST="${FLAKY_FAIL_FIRST:-10}"
FLAKY_PID=""

cleanup() {
  if [ -n "${FLAKY_PID:-}" ] && kill -0 "$FLAKY_PID" >/dev/null 2>&1; then
    kill "$FLAKY_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ADMIN_LOGIN_JSON="$(login_json "$ADMIN_EMAIL" "$ADMIN_PASSWORD")"
ADMIN_TOKEN="$(json_field "$ADMIN_LOGIN_JSON" '.access_token')"
ADMIN_USER_ID="$(json_field "$ADMIN_LOGIN_JSON" '.user_id')"

TENANT_ID="$(create_tenant "Tenant T31 Webhook Retry $(date +%s)")"
grant_membership "$TENANT_ID" "$ADMIN_USER_ID" "admin"

SENSOR_JSON="$(create_sensor_for_tenant "$ADMIN_TOKEN" "$TENANT_ID" "sensor-webhook-t31")"
SENSOR_ID="$(echo "$SENSOR_JSON" | jq -r .sensor_id)"
SENSOR_TOKEN="$(echo "$SENSOR_JSON" | jq -r .sensor_token)"

info "Levantando webhook flaky local"
python3 scripts/mock_webhook_flaky_receiver.py "$FLAKY_CAPTURE_FILE" "$FLAKY_PORT" "$FLAKY_FAIL_FIRST" >"$FLAKY_LOG" 2>&1 &
FLAKY_PID=$!

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$FLAKY_PORT/health" >/dev/null 2>&1; then
    ok "Mock webhook flaky listo"
    break
  fi
  sleep 1
done

curl -fsS "http://127.0.0.1:$FLAKY_PORT/health" >/dev/null 2>&1 || die "El mock webhook flaky no quedó listo"

info "Configurando webhook del tenant"
assert_http_code 200 \
  -X PUT "$API/v1/tenants/$TENANT_ID/webhook" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"webhook_url\":\"http://host.docker.internal:$FLAKY_PORT/hook\",\"webhook_min_severity\":1}"

EVENT_FILE="$TMP_DIR/retry_event.json"
EVENT_ID="$(write_event_json \
  "$EVENT_FILE" \
  "$TENANT_ID" \
  "$SENSOR_ID" \
  "http" \
  "198.51.100.200" \
  "47001" \
  "2026-03-29T21:30:01Z" \
  '{"username":null,"ssh_auth_method":null,"http_user_agent":"retry-test","http_method":"GET","http_path":"/login","decoy_hit":null,"decoy_kind":null}'
)"

info "Enviando evento para disparar webhook"
INGEST_JSON="$(curl -sS -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$EVENT_FILE")"

assert_json_condition "$INGEST_JSON" '.ingested == true' "El evento no fue ingerido"
assert_json_condition "$INGEST_JSON" '.webhook_delivery_id != null' "No se creó webhook_delivery_id"

info "Esperando estado final failed tras reintentos"
DELIVERY_JSON="$(wait_for_delivery_status "$TENANT_ID" "$EVENT_ID" "failed" 40 "$ADMIN_TOKEN")"

assert_json_condition \
  "$DELIVERY_JSON" \
  '.[0].attempt_count == 4' \
  "La entrega no llegó a 4 intentos"

assert_json_condition \
  "$DELIVERY_JSON" \
  '.[0].status == "failed"' \
  "La entrega no terminó en failed"

assert_json_condition \
  "$DELIVERY_JSON" \
  '(.[0].attempts | length) == 4' \
  "No hay 4 intentos registrados"

assert_json_condition \
  "$DELIVERY_JSON" \
  'all(.[0].attempts[]; .success == false)' \
  "Algún intento salió exitoso cuando debía fallar"

assert_json_condition \
  "$DELIVERY_JSON" \
  'all(.[0].attempts[]; .http_status == 500)' \
  "Los intentos no quedaron con http_status=500"

python3 - "$FLAKY_CAPTURE_FILE" <<'PY'
import sys
from pathlib import Path

capture = Path(sys.argv[1])
if not capture.exists():
    raise SystemExit(1)

lines = [line for line in capture.read_text(encoding="utf-8").splitlines() if line.strip()]
if len(lines) < 4:
    raise SystemExit(1)
PY

ok "T31 webhook retries + historial visible: OK"