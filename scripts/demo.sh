#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${API:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@acme.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

# IMPORTANTE:
# - Por defecto NO fuerza build.
# - Si ya tienes el stack arriba o las imágenes locales, reutiliza eso.
DM_FORCE_BUILD="${DM_FORCE_BUILD:-0}"
DM_SKIP_STACK_BOOT="${DM_SKIP_STACK_BOOT:-0}"

WEBHOOK_PORT="${WEBHOOK_PORT:-18080}"
HTTP_TRAP_PORT="${HTTP_TRAP_PORT:-18082}"
SSH_TRAP_PORT="${SSH_TRAP_PORT:-22222}"
HTTP_TRAP_PATH="${HTTP_TRAP_PATH:-/login}"
HTTP_USER_AGENT="${HTTP_USER_AGENT:-DeceptionMeshDemo/1.0}"

EVENT_VISIBILITY_TIMEOUT_SECONDS="${EVENT_VISIBILITY_TIMEOUT_SECONDS:-10}"
WEBHOOK_DELIVERY_TIMEOUT_SECONDS="${WEBHOOK_DELIVERY_TIMEOUT_SECONDS:-15}"

TMP_DIR="${TMP_DIR:-$(mktemp -d /tmp/deceptionmesh_t30.XXXXXX)}"
WEBHOOK_CAPTURE_FILE="${WEBHOOK_CAPTURE_FILE:-$TMP_DIR/webhooks.jsonl}"
SENSOR_CONFIG="$TMP_DIR/sensor.demo.toml"
SENSOR_LOG="$TMP_DIR/sensor_agent.log"
WEBHOOK_LOG="$TMP_DIR/mock_webhook.log"

TOKEN=""
USER_ID=""
TENANT_ID=""
SENSOR_ID=""
SENSOR_TOKEN=""
SENSOR_PID=""
WEBHOOK_PID=""
LAST_WAIT_SECONDS=0

ok()   { echo -e "✅ $*"; }
info() { echo -e "ℹ️  $*"; }
warn() { echo -e "⚠️  $*"; }
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

http_code() {
  curl -sS -o /dev/null -w "%{http_code}" "$@" || true
}

api_is_healthy() {
  [ "$(http_code "$API/health")" = "200" ]
}

cleanup() {
  if [ -n "${SENSOR_PID:-}" ] && kill -0 "$SENSOR_PID" >/dev/null 2>&1; then
    kill "$SENSOR_PID" >/dev/null 2>&1 || true
  fi

  if [ -n "${WEBHOOK_PID:-}" ] && kill -0 "$WEBHOOK_PID" >/dev/null 2>&1; then
    kill "$WEBHOOK_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

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
  docker logs deceptionmesh-control-plane --tail 200 >&2 || true
  die "$name no respondió 200 a tiempo"
}

wait_for_local_http_health() {
  local url="$1"
  local name="$2"

  for _ in $(seq 1 30); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      ok "$name listo"
      return 0
    fi
    sleep 1
  done

  [ -f "$WEBHOOK_LOG" ] && tail -n 200 "$WEBHOOK_LOG" >&2 || true
  die "$name no quedó listo"
}

wait_for_local_tcp() {
  local host="$1"
  local port="$2"
  local name="$3"

  for _ in $(seq 1 60); do
    if python3 - "$host" "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(1.0)
try:
    s.connect((host, port))
except OSError:
    raise SystemExit(1)
else:
    s.close()
    raise SystemExit(0)
PY
    then
      ok "$name escuchando en $host:$port"
      return 0
    fi

    if [ -n "${SENSOR_PID:-}" ] && ! kill -0 "$SENSOR_PID" >/dev/null 2>&1; then
      [ -f "$SENSOR_LOG" ] && tail -n 200 "$SENSOR_LOG" >&2 || true
      die "sensor_agent terminó antes de abrir $name"
    fi

    sleep 1
  done

  [ -f "$SENSOR_LOG" ] && tail -n 200 "$SENSOR_LOG" >&2 || true
  die "$name no abrió puerto a tiempo"
}

wait_for_event_json() {
  local tenant_id="$1"
  local service="$2"
  local jq_filter="$3"
  local timeout_seconds="$4"
  local label="$5"

  local started_at
  started_at="$(date +%s)"

  while true; do
    local payload
    payload="$(curl -sS \
      "$API/v1/tenants/$tenant_id/events?service=$service&limit=50" \
      -H "Authorization: Bearer $TOKEN")"

    if echo "$payload" | jq -e "$jq_filter" >/dev/null 2>&1; then
      LAST_WAIT_SECONDS=$(( $(date +%s) - started_at ))
      printf '%s' "$payload"
      return 0
    fi

    if [ $(( $(date +%s) - started_at )) -gt "$timeout_seconds" ]; then
      echo "$payload" >&2
      die "$label no apareció en <= ${timeout_seconds}s"
    fi

    sleep 1
  done
}

wait_for_delivery_json() {
  local tenant_id="$1"
  local event_id="$2"
  local timeout_seconds="$3"
  local label="$4"

  local started_at
  started_at="$(date +%s)"

  while true; do
    local payload
    payload="$(curl -sS \
      "$API/v1/tenants/$tenant_id/webhook-deliveries?event_id=$event_id" \
      -H "Authorization: Bearer $TOKEN")"

    if echo "$payload" | jq -e '.[0].status == "delivered"' >/dev/null 2>&1; then
      LAST_WAIT_SECONDS=$(( $(date +%s) - started_at ))
      printf '%s' "$payload"
      return 0
    fi

    if [ $(( $(date +%s) - started_at )) -gt "$timeout_seconds" ]; then
      echo "$payload" >&2
      die "$label no quedó delivered en <= ${timeout_seconds}s"
    fi

    sleep 1
  done
}

assert_webhook_capture_contains_event() {
  local capture_file="$1"
  local event_id="$2"

  python3 - "$capture_file" "$event_id" <<'PY'
import json
import sys
from pathlib import Path

capture = Path(sys.argv[1])
event_id = sys.argv[2]

if not capture.exists():
    raise SystemExit(1)

for line in capture.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue

    payload = json.loads(line)
    if payload.get("version") == "deception_mesh.event.v1" and payload.get("event", {}).get("id") == event_id:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        raise SystemExit(0)

raise SystemExit(1)
PY
}

ensure_stack() {
  if [ "$DM_SKIP_STACK_BOOT" = "1" ]; then
    info "DM_SKIP_STACK_BOOT=1, no tocaré docker compose"
    return 0
  fi

  if api_is_healthy; then
    ok "Reutilizando stack ya levantado"
    return 0
  fi

  if [ "$DM_FORCE_BUILD" = "1" ]; then
    info "Intentando levantar stack con build forzado"
    if docker compose up -d --build >/dev/null; then
      return 0
    fi

    warn "Falló el build. Intentaré reutilizar contenedores/imágenes locales sin rebuild"

    if docker compose up -d --no-build >/dev/null; then
      return 0
    fi

    if api_is_healthy; then
      warn "El API quedó disponible pese al fallo de build; continúo"
      return 0
    fi

    die "No pude levantar el stack. El error parece de DNS/salida a Docker Hub. Usa DM_FORCE_BUILD=0 para reutilizar lo que ya está construido."
  fi

  info "Intentando levantar stack SIN build"
  if docker compose up -d --no-build >/dev/null; then
    return 0
  fi

  if api_is_healthy; then
    ok "El API ya estaba arriba; continúo"
    return 0
  fi

  warn "No se pudo levantar sin build. Intentaré build como último recurso"
  if docker compose up -d --build >/dev/null; then
    return 0
  fi

  if api_is_healthy; then
    warn "El build falló pero el API quedó disponible; continúo"
    return 0
  fi

  die "No pude levantar el stack. Si aparece registry-1.docker.io o timeout DNS, el problema es Docker Hub/DNS y no tu código."
}

need docker
need curl
need jq
need python3
need cargo
need ssh

info "Preparando stack base"
ensure_stack

wait_for_http_200 "$API/health" "/health"
wait_for_http_200 "$API/ready" "/ready"

info "Compilando sensor_agent para acelerar la demo"
cargo build -p sensor_agent >/dev/null

info "Levantando mock webhook local"
python3 scripts/mock_webhook_receiver.py "$WEBHOOK_CAPTURE_FILE" "$WEBHOOK_PORT" >"$WEBHOOK_LOG" 2>&1 &
WEBHOOK_PID=$!

wait_for_local_http_health "http://127.0.0.1:$WEBHOOK_PORT/health" "Mock webhook"

info "Autenticando admin seed"
LOGIN_JSON="$(curl -sS -X POST "$API/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")"

TOKEN="$(echo "$LOGIN_JSON" | jq -r .access_token)"
USER_ID="$(echo "$LOGIN_JSON" | jq -r .user_id)"

[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || die "No se obtuvo access_token"
[ -n "$USER_ID" ] && [ "$USER_ID" != "null" ] || die "No se obtuvo user_id"

DB_NAME="$(docker compose exec -T postgres printenv POSTGRES_DB | tr -d '\r')"
PGUSER="$(docker compose exec -T postgres printenv POSTGRES_USER | tr -d '\r')"

TENANT_ID="$(uuid)"
TENANT_NAME="Tenant Demo T30 $(date +%s)"

info "Creando tenant demo"
docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
  "INSERT INTO tenants (id, name) VALUES ('$TENANT_ID','$TENANT_NAME') ON CONFLICT DO NOTHING;" >/dev/null

docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
  "INSERT INTO memberships (tenant_id, user_id, role) VALUES ('$TENANT_ID','$USER_ID','admin') ON CONFLICT DO NOTHING;" >/dev/null

info "Generando enroll token"
ENROLL_JSON="$(curl -sS -X POST "$API/v1/tenants/$TENANT_ID/sensors/enroll-token" \
  -H "Authorization: Bearer $TOKEN")"
ENROLL_TOKEN="$(echo "$ENROLL_JSON" | jq -r .enroll_token)"
[ -n "$ENROLL_TOKEN" ] && [ "$ENROLL_TOKEN" != "null" ] || die "No se obtuvo enroll_token"

info "Registrando sensor demo"
REGISTER_JSON="$(curl -sS -X POST "$API/sensors/register" \
  -H "Content-Type: application/json" \
  -d "{\"tenant_id\":\"$TENANT_ID\",\"enroll_token\":\"$ENROLL_TOKEN\",\"name\":\"sensor-demo-t30\"}")"

SENSOR_ID="$(echo "$REGISTER_JSON" | jq -r .sensor_id)"
SENSOR_TOKEN="$(echo "$REGISTER_JSON" | jq -r .sensor_token)"
[ -n "$SENSOR_ID" ] && [ "$SENSOR_ID" != "null" ] || die "No se obtuvo sensor_id"
[ -n "$SENSOR_TOKEN" ] && [ "$SENSOR_TOKEN" != "null" ] || die "No se obtuvo sensor_token"

info "Configurando webhook del tenant"
WEBHOOK_CFG_JSON="$(curl -sS -X PUT "$API/v1/tenants/$TENANT_ID/webhook" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"webhook_url\":\"http://host.docker.internal:$WEBHOOK_PORT/hook\",\"webhook_min_severity\":1}")"

[ "$(echo "$WEBHOOK_CFG_JSON" | jq -r .tenant_id)" = "$TENANT_ID" ] || die "No se configuró el webhook"
[ "$(echo "$WEBHOOK_CFG_JSON" | jq -r .webhook_min_severity)" = "1" ] || die "El webhook_min_severity no quedó en 1"

info "Verificando que el sensor quedó visible en API"
SENSORS_JSON="$(curl -sS "$API/v1/tenants/$TENANT_ID/sensors" \
  -H "Authorization: Bearer $TOKEN")"
echo "$SENSORS_JSON" | jq -e --arg sensor_id "$SENSOR_ID" '.[] | select(.id == $sensor_id)' >/dev/null \
  || die "El sensor no quedó visible en el inventario"

cat > "$SENSOR_CONFIG" <<EOF
[sensor]
tenant_id = "$TENANT_ID"
sensor_id = "$SENSOR_ID"
sensor_token = "$SENSOR_TOKEN"

[control_plane]
base_url = "$API"
heartbeat_path = "/sensors/{sensor_id}/heartbeat"
ingest_path = "/events/ingest"
request_timeout_seconds = 10

[runtime]
heartbeat_interval_seconds = 30
max_queue = 10000

[logging]
level = "info"
format = "pretty"

[honeypots]
ssh_listen_addr = "127.0.0.1:$SSH_TRAP_PORT"
ssh_banner = "OpenSSH_8.9p1 Ubuntu-3ubuntu0.10"
http_listen_addr = "127.0.0.1:$HTTP_TRAP_PORT"
http_trap_paths = ["$HTTP_TRAP_PATH", "/admin", "/wp-login.php"]
EOF

info "Levantando sensor_agent demo"
cargo run -p sensor_agent -- --config "$SENSOR_CONFIG" >"$SENSOR_LOG" 2>&1 &
SENSOR_PID=$!

wait_for_local_tcp "127.0.0.1" "$HTTP_TRAP_PORT" "HTTP honeypot"
wait_for_local_tcp "127.0.0.1" "$SSH_TRAP_PORT" "SSH honeypot"

info "Disparando toque HTTP"
curl -fsS -A "$HTTP_USER_AGENT" "http://127.0.0.1:$HTTP_TRAP_PORT$HTTP_TRAP_PATH" >/dev/null

HTTP_EVENTS_JSON="$(wait_for_event_json \
  "$TENANT_ID" \
  "http" \
  ".items[]? | select(.raw_event.evidence.http_path == \"$HTTP_TRAP_PATH\")" \
  "$EVENT_VISIBILITY_TIMEOUT_SECONDS" \
  "Evento HTTP")"
HTTP_EVENT_VISIBLE_SECONDS="$LAST_WAIT_SECONDS"

HTTP_EVENT_ROW="$(echo "$HTTP_EVENTS_JSON" | jq -c --arg p "$HTTP_TRAP_PATH" '.items[] | select(.raw_event.evidence.http_path == $p) | .' | head -n 1)"
HTTP_EVENT_ID="$(echo "$HTTP_EVENT_ROW" | jq -r .id)"

[ -n "$HTTP_EVENT_ID" ] && [ "$HTTP_EVENT_ID" != "null" ] || die "No se pudo extraer event_id HTTP"
ok "Evento HTTP visible en API en ${HTTP_EVENT_VISIBLE_SECONDS}s"

HTTP_DELIVERY_JSON="$(wait_for_delivery_json \
  "$TENANT_ID" \
  "$HTTP_EVENT_ID" \
  "$WEBHOOK_DELIVERY_TIMEOUT_SECONDS" \
  "Webhook HTTP")"
HTTP_WEBHOOK_SECONDS="$LAST_WAIT_SECONDS"
ok "Webhook HTTP delivered en ${HTTP_WEBHOOK_SECONDS}s"

HTTP_WEBHOOK_CAPTURE="$(assert_webhook_capture_contains_event "$WEBHOOK_CAPTURE_FILE" "$HTTP_EVENT_ID")" \
  || die "No encontré el webhook HTTP versionado en el archivo de captura"
ok "Webhook HTTP versionado confirmado"

info "Disparando toque SSH"
ssh \
  -o ConnectTimeout=3 \
  -o BatchMode=yes \
  -o PubkeyAuthentication=no \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -p "$SSH_TRAP_PORT" \
  demo@127.0.0.1 exit >/dev/null 2>&1 || true

SSH_EVENTS_JSON="$(wait_for_event_json \
  "$TENANT_ID" \
  "ssh" \
  '.items[]? | select(.service == "ssh")' \
  "$EVENT_VISIBILITY_TIMEOUT_SECONDS" \
  "Evento SSH")"
SSH_EVENT_VISIBLE_SECONDS="$LAST_WAIT_SECONDS"

SSH_EVENT_ROW="$(echo "$SSH_EVENTS_JSON" | jq -c '.items[] | select(.service == "ssh") | .' | head -n 1)"
SSH_EVENT_ID="$(echo "$SSH_EVENT_ROW" | jq -r .id)"

[ -n "$SSH_EVENT_ID" ] && [ "$SSH_EVENT_ID" != "null" ] || die "No se pudo extraer event_id SSH"
ok "Evento SSH visible en API en ${SSH_EVENT_VISIBLE_SECONDS}s"

SSH_DELIVERY_JSON="$(wait_for_delivery_json \
  "$TENANT_ID" \
  "$SSH_EVENT_ID" \
  "$WEBHOOK_DELIVERY_TIMEOUT_SECONDS" \
  "Webhook SSH")"
SSH_WEBHOOK_SECONDS="$LAST_WAIT_SECONDS"
ok "Webhook SSH delivered en ${SSH_WEBHOOK_SECONDS}s"

SSH_WEBHOOK_CAPTURE="$(assert_webhook_capture_contains_event "$WEBHOOK_CAPTURE_FILE" "$SSH_EVENT_ID")" \
  || die "No encontré el webhook SSH versionado en el archivo de captura"
ok "Webhook SSH versionado confirmado"

echo
ok "T30 completada: demo extremo a extremo reproducible"
echo

echo "================ RESUMEN HTTP ================"
echo "$HTTP_EVENT_ROW" | jq .
echo
echo "================ ENTREGA HTTP ================"
echo "$HTTP_DELIVERY_JSON" | jq '.[0]'
echo
echo "================ WEBHOOK HTTP ================"
echo "$HTTP_WEBHOOK_CAPTURE" | jq .
echo

echo "================ RESUMEN SSH ================"
echo "$SSH_EVENT_ROW" | jq .
echo
echo "================ ENTREGA SSH ================"
echo "$SSH_DELIVERY_JSON" | jq '.[0]'
echo
echo "================ WEBHOOK SSH ================"
echo "$SSH_WEBHOOK_CAPTURE" | jq .
echo

info "Logs del sensor: $SENSOR_LOG"
info "Logs del mock webhook: $WEBHOOK_LOG"
info "Capturas webhook: $WEBHOOK_CAPTURE_FILE"
info "Config temporal sensor: $SENSOR_CONFIG"