#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/deploy/runtime/quickstart.state.json"

info() { echo "ℹ️  $*"; }
ok() { echo "✅ $*"; }
die() { echo "❌ $*" >&2; exit 1; }

bash "$ROOT_DIR/scripts/t29_install_mvp_local.sh"

[ -f "$STATE_FILE" ] || die "No se generó $STATE_FILE"

TENANT_ID="$(jq -r '.tenant_id' "$STATE_FILE")"
SENSOR_ID="$(jq -r '.sensor_id' "$STATE_FILE")"
ADMIN_USER_ID="$(jq -r '.admin_user_id' "$STATE_FILE")"
API_BASE_URL="$(jq -r '.control_plane_url' "$STATE_FILE")"

[ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ] || die "tenant_id inválido"
[ -n "$SENSOR_ID" ] && [ "$SENSOR_ID" != "null" ] || die "sensor_id inválido"
[ -n "$ADMIN_USER_ID" ] && [ "$ADMIN_USER_ID" != "null" ] || die "admin_user_id inválido"
[ -n "$API_BASE_URL" ] && [ "$API_BASE_URL" != "null" ] || die "control_plane_url inválido"

SENSORS_JSON="$(
  curl -fsS \
    -H "x-user-id: $ADMIN_USER_ID" \
    "$API_BASE_URL/v1/tenants/$TENANT_ID/sensors"
)"

STATUS="$(echo "$SENSORS_JSON" | jq -r --arg sid "$SENSOR_ID" '.[] | select(.id == $sid) | .status' | head -n1)"
LAST_SEEN="$(echo "$SENSORS_JSON" | jq -r --arg sid "$SENSOR_ID" '.[] | select(.id == $sid) | .last_seen' | head -n1)"

[ "$STATUS" = "active" ] || die "El sensor quickstart no está active"
[ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" != "null" ] || die "El sensor quickstart no reportó heartbeat real"

curl -fsS http://localhost:8081/login >/dev/null

ok "T29 quickstart MVP: OK"