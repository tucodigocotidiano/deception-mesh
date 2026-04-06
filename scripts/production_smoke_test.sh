#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.production}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/compose.production.yml}"

usage() {
  echo "Uso: $0 <admin_email> <admin_password> <tenant_id>" >&2
  exit 1
}

[ "$#" -eq 3 ] || usage

ADMIN_EMAIL="$1"
ADMIN_PASSWORD="$2"
TENANT_ID="$3"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Falta comando requerido: $1" >&2
    exit 1
  }
}

require_cmd curl
require_cmd python3
require_cmd ssh

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

BASE_URL="http://127.0.0.1:${CONTROL_PLANE_HOST_PORT:-18080}"
HTTP_URL="http://127.0.0.1:${SENSOR_HTTP_PORT:-8081}"
SSH_PORT="${SENSOR_SSH_PORT:-2222}"

echo "==> health"
curl -fsS "$BASE_URL/health"
echo
echo "==> ready"
curl -fsS "$BASE_URL/ready"
echo
echo

echo "==> Login admin"
LOGIN_JSON="$(curl -fsS -X POST "$BASE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")"

TOKEN="$(printf '%s' "$LOGIN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

echo "==> Listando sensores"
curl -fsS "$BASE_URL/v1/tenants/$TENANT_ID/sensors" \
  -H "Authorization: Bearer $TOKEN"
echo
echo

echo "==> Disparando rutas HTTP trampa"
curl -fsS "$HTTP_URL/login" >/dev/null
curl -fsS "$HTTP_URL/admin" >/dev/null
curl -fsS "$HTTP_URL/wp-login.php" >/dev/null

echo "==> Disparando intento SSH simple"
timeout 8s ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=none \
  -o PubkeyAuthentication=no \
  demo@127.0.0.1 \
  -p "$SSH_PORT" true || true

sleep 3

echo
echo "==> Eventos HTTP"
curl -fsS "$BASE_URL/v1/tenants/$TENANT_ID/events?service=http&limit=20" \
  -H "Authorization: Bearer $TOKEN"
echo
echo

echo "==> Eventos SSH"
curl -fsS "$BASE_URL/v1/tenants/$TENANT_ID/events?service=ssh&limit=20" \
  -H "Authorization: Bearer $TOKEN"
echo
echo

CSV_OUT="/tmp/deception_mesh_smoke_${TENANT_ID}.csv"
echo "==> Exportando CSV a $CSV_OUT"
curl -fsS "$BASE_URL/events/export.csv?tenant_id=$TENANT_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -o "$CSV_OUT"

echo "✅ Smoke test listo"
echo "CSV: $CSV_OUT"