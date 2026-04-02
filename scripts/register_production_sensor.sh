#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.production}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/compose.production.yml}"
OUTPUT_FILE="${OUTPUT_FILE:-$ROOT_DIR/deploy/runtime/sensor.production.toml}"

usage() {
  echo "Uso: $0 <admin_email> <admin_password> <tenant_id> <sensor_name>" >&2
  exit 1
}

[ "$#" -eq 4 ] || usage

ADMIN_EMAIL="$1"
ADMIN_PASSWORD="$2"
TENANT_ID="$3"
SENSOR_NAME="$4"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Falta comando requerido: $1" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl
require_cmd python3

if [ ! -f "$ENV_FILE" ]; then
  echo "Falta $ENV_FILE" >&2
  exit 1
fi

load_env_file() {
  local tmp_env
  tmp_env="$(mktemp)"
  tr -d '\r' < "$ENV_FILE" > "$tmp_env"
  # shellcheck disable=SC1090
  set -a
  source "$tmp_env"
  set +a
  rm -f "$tmp_env"
}

load_env_file

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
BASE_URL="http://127.0.0.1:${CONTROL_PLANE_HOST_PORT:-18080}"
SENSOR_CONTROL_PLANE_BASE_URL="${SENSOR_CONTROL_PLANE_BASE_URL:-http://control_plane:8080}"

echo "==> Asegurando control_plane arriba"
"${COMPOSE[@]}" up -d postgres control_plane

for _ in $(seq 1 60); do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

curl -fsS "$BASE_URL/health" >/dev/null 2>&1 || {
  echo "control_plane no responde" >&2
  exit 1
}

echo "==> Login admin"
LOGIN_JSON="$(curl -fsS -X POST "$BASE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")"

TOKEN="$(printf '%s' "$LOGIN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

echo "==> Generando enroll token"
ENROLL_JSON="$(curl -fsS -X POST "$BASE_URL/v1/tenants/$TENANT_ID/sensors/enroll-token" \
  -H "Authorization: Bearer $TOKEN")"

ENROLL_TOKEN="$(printf '%s' "$ENROLL_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["enroll_token"])')"

echo "==> Registrando sensor"
REGISTER_JSON="$(curl -fsS -X POST "$BASE_URL/sensors/register" \
  -H "Content-Type: application/json" \
  -d "{\"tenant_id\":\"$TENANT_ID\",\"enroll_token\":\"$ENROLL_TOKEN\",\"name\":\"$SENSOR_NAME\"}")"

SENSOR_ID="$(printf '%s' "$REGISTER_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sensor_id"])')"
SENSOR_TOKEN="$(printf '%s' "$REGISTER_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sensor_token"])')"

mkdir -p "$(dirname "$OUTPUT_FILE")"

cat > "$OUTPUT_FILE" <<EOF
[sensor]
tenant_id = "$TENANT_ID"
sensor_id = "$SENSOR_ID"
sensor_token = "$SENSOR_TOKEN"

[control_plane]
base_url = "$SENSOR_CONTROL_PLANE_BASE_URL"
heartbeat_path = "/sensors/{sensor_id}/heartbeat"
ingest_path = "/events/ingest"
request_timeout_seconds = 10

[runtime]
heartbeat_interval_seconds = 15
max_queue = 10000

[logging]
level = "info"
format = "pretty"

[honeypots]
ssh_listen_addr = "0.0.0.0:2222"
ssh_banner = "OpenSSH_8.9p1 Ubuntu-3ubuntu0.10"
http_listen_addr = "0.0.0.0:8081"
https_listen_addr = ""
http_trap_paths = ["/login", "/admin", "/wp-login.php"]
EOF

echo
echo "✅ sensor.production.toml generado en:"
echo "$OUTPUT_FILE"
echo
echo "==> Levantando sensor_agent"
"${COMPOSE[@]}" up -d --force-recreate sensor_agent

echo
echo "Sensor ID:    $SENSOR_ID"
echo "Sensor name:  $SENSOR_NAME"
echo "Tenant ID:    $TENANT_ID"