#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/deploy/runtime"
CONFIG_FILE="$RUNTIME_DIR/sensor.toml"
STATE_FILE="$RUNTIME_DIR/quickstart.state.json"

DEFAULT_CP_PORT="${QUICKSTART_CONTROL_PLANE_HOST_PORT:-8080}"
DEFAULT_SSH_PORT="${QUICKSTART_SENSOR_SSH_PORT:-2222}"
DEFAULT_HTTP_PORT="${QUICKSTART_SENSOR_HTTP_PORT:-8081}"
DEFAULT_HTTPS_PORT="${QUICKSTART_SENSOR_HTTPS_PORT:-8443}"

ADMIN_USER_ID="${QUICKSTART_ADMIN_USER_ID:-11111111-1111-1111-1111-111111111111}"
ADMIN_EMAIL="${QUICKSTART_ADMIN_EMAIL:-quickstart-admin-${ADMIN_USER_ID}@local.invalid}"
TENANT_NAME="${QUICKSTART_TENANT_NAME:-Quickstart Tenant $(date +%s)}"
SENSOR_NAME="${QUICKSTART_SENSOR_NAME:-sensor-mvp-local}"
CONTROL_PLANE_INTERNAL_URL="${QUICKSTART_CONTROL_PLANE_INTERNAL_URL:-http://control_plane:8080}"

SSH_LISTEN_ADDR="${QUICKSTART_SSH_LISTEN_ADDR:-0.0.0.0:2222}"
HTTP_LISTEN_ADDR="${QUICKSTART_HTTP_LISTEN_ADDR:-0.0.0.0:8081}"
HTTPS_LISTEN_ADDR="${QUICKSTART_HTTPS_LISTEN_ADDR:-}"

info() { echo "ℹ️  $*"; }
ok() { echo "✅ $*"; }
die() { echo "❌ $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta dependencia: $1"
}

port_in_use() {
  python3 - "$1" <<'PY'
import socket, sys
port = int(sys.argv[1])
for family, host in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
    try:
        s = socket.socket(family, socket.SOCK_STREAM)
        s.settimeout(0.2)
        s.connect((host, port))
    except OSError:
        pass
    else:
        s.close()
        raise SystemExit(0)
raise SystemExit(1)
PY
}

choose_port() {
  local preferred="$1"
  shift

  if ! port_in_use "$preferred"; then
    echo "$preferred"
    return 0
  fi

  for candidate in "$@"; do
    if ! port_in_use "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  die "No encontré puerto libre para base $preferred"
}

http_code() {
  curl -sS -o /dev/null -w "%{http_code}" "$1" || true
}

wait_for_http_200() {
  local url="$1"
  local label="$2"
  local attempts="${3:-60}"

  for _ in $(seq 1 "$attempts"); do
    if [ "$(http_code "$url")" = "200" ]; then
      ok "$label responde 200"
      return 0
    fi
    sleep 2
  done

  die "$label no respondió 200 a tiempo ($url)"
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

json_field() {
  local json="$1"
  local filter="$2"
  echo "$json" | jq -r "$filter"
}

require_cmd docker
require_cmd curl
require_cmd jq

docker compose version >/dev/null 2>&1 || die "No está disponible docker compose plugin"

mkdir -p "$RUNTIME_DIR"

LOCAL_CONTROL_PLANE_HOST_PORT="$(choose_port "$DEFAULT_CP_PORT" 18080 28080 38080)"
LOCAL_SENSOR_SSH_PORT="$(choose_port "$DEFAULT_SSH_PORT" 2223 3222 4222)"
LOCAL_SENSOR_HTTP_PORT="$(choose_port "$DEFAULT_HTTP_PORT" 18081 28081 38081)"
LOCAL_SENSOR_HTTPS_PORT="$(choose_port "$DEFAULT_HTTPS_PORT" 18443 28443 38443)"

export LOCAL_CONTROL_PLANE_HOST_PORT LOCAL_SENSOR_SSH_PORT LOCAL_SENSOR_HTTP_PORT LOCAL_SENSOR_HTTPS_PORT
API_BASE_URL="http://127.0.0.1:${LOCAL_CONTROL_PLANE_HOST_PORT}"

psql_exec() {
  docker compose exec -T postgres \
    psql -U deception -d deception_mesh -v ON_ERROR_STOP=1 "$@"
}

info "Puertos elegidos: control_plane=$LOCAL_CONTROL_PLANE_HOST_PORT ssh=$LOCAL_SENSOR_SSH_PORT http=$LOCAL_SENSOR_HTTP_PORT https=$LOCAL_SENSOR_HTTPS_PORT"
info "Levantando stack base del control plane"
(
  cd "$ROOT_DIR"
  docker compose up -d --build postgres control_plane
)

wait_for_http_200 "$API_BASE_URL/health" "/health"
wait_for_http_200 "$API_BASE_URL/ready" "/ready"

ADMIN_EMAIL_SQL="$(sql_escape "$ADMIN_EMAIL")"
TENANT_NAME_SQL="$(sql_escape "$TENANT_NAME")"

info "Asegurando usuario admin bootstrap local"
psql_exec -Atqc "
  INSERT INTO users (id, email, password_hash)
  VALUES (
    '$ADMIN_USER_ID'::uuid,
    '$ADMIN_EMAIL_SQL',
    NULL
  )
  ON CONFLICT (id) DO UPDATE
  SET email = EXCLUDED.email;
" >/dev/null

ok "Usuario bootstrap listo: $ADMIN_USER_ID"

info "Creando tenant quickstart y membership admin por bootstrap local"
TENANT_ID="$(
  psql_exec -Atqc "
    WITH inserted AS (
      INSERT INTO tenants (name)
      VALUES ('$TENANT_NAME_SQL')
      RETURNING id
    ),
    membership_upsert AS (
      INSERT INTO memberships (tenant_id, user_id, role)
      SELECT id, '$ADMIN_USER_ID'::uuid, 'admin'::role_kind
      FROM inserted
      ON CONFLICT (tenant_id, user_id) DO UPDATE
      SET role = EXCLUDED.role
      RETURNING tenant_id
    )
    SELECT id FROM inserted;
  " | tr -d '[:space:]'
)"

[ -n "$TENANT_ID" ] || die "No se pudo crear tenant quickstart"

info "Generando enroll token"
ENROLL_JSON="$(
  curl -fsS \
    -X POST \
    -H "x-user-id: $ADMIN_USER_ID" \
    "$API_BASE_URL/v1/tenants/$TENANT_ID/sensors/enroll-token"
)"

ENROLL_TOKEN="$(json_field "$ENROLL_JSON" '.enroll_token')"
[ -n "$ENROLL_TOKEN" ] && [ "$ENROLL_TOKEN" != "null" ] || die "No se obtuvo enroll_token"

info "Registrando sensor MVP"
REGISTER_PAYLOAD="$(
  jq -n \
    --arg tenant_id "$TENANT_ID" \
    --arg enroll_token "$ENROLL_TOKEN" \
    --arg name "$SENSOR_NAME" \
    '{
      tenant_id: $tenant_id,
      enroll_token: $enroll_token,
      name: $name
    }'
)"

SENSOR_JSON="$(
  curl -fsS \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$REGISTER_PAYLOAD" \
    "$API_BASE_URL/sensors/register"
)"

SENSOR_ID="$(json_field "$SENSOR_JSON" '.sensor_id')"
SENSOR_TOKEN="$(json_field "$SENSOR_JSON" '.sensor_token')"

[ -n "$SENSOR_ID" ] && [ "$SENSOR_ID" != "null" ] || die "No se obtuvo sensor_id"
[ -n "$SENSOR_TOKEN" ] && [ "$SENSOR_TOKEN" != "null" ] || die "No se obtuvo sensor_token"

info "Generando config runtime del sensor en $CONFIG_FILE"
cat > "$CONFIG_FILE" <<EOF
[sensor]
tenant_id = "$TENANT_ID"
sensor_id = "$SENSOR_ID"
sensor_token = "$SENSOR_TOKEN"

[control_plane]
base_url = "$CONTROL_PLANE_INTERNAL_URL"
heartbeat_path = "/sensors/{sensor_id}/heartbeat"
ingest_path = "/events/ingest"
request_timeout_seconds = 10

[runtime]
heartbeat_interval_seconds = 5
max_queue = 10000

[logging]
level = "info"
format = "pretty"

[honeypots]
ssh_listen_addr = "$SSH_LISTEN_ADDR"
ssh_banner = "OpenSSH_8.9p1 Ubuntu-3ubuntu0.10"
http_listen_addr = "$HTTP_LISTEN_ADDR"
https_listen_addr = "$HTTPS_LISTEN_ADDR"
http_trap_paths = ["/login", "/admin", "/wp-login.php"]
EOF

info "Levantando sensor_agent por profile docker compose"
(
  cd "$ROOT_DIR"
  docker compose --profile sensor up -d --build --force-recreate sensor_agent
)

info "Validando que el sensor quede active con heartbeat real"
LAST_SEEN=""
STATUS=""

for _ in $(seq 1 30); do
  SENSORS_JSON="$(
    curl -fsS \
      -H "x-user-id: $ADMIN_USER_ID" \
      "$API_BASE_URL/v1/tenants/$TENANT_ID/sensors" || true
  )"

  if [ -n "$SENSORS_JSON" ] && [ "$SENSORS_JSON" != "null" ]; then
    STATUS="$(echo "$SENSORS_JSON" | jq -r --arg sid "$SENSOR_ID" '.[] | select(.id == $sid) | .status' | head -n1)"
    LAST_SEEN="$(echo "$SENSORS_JSON" | jq -r --arg sid "$SENSOR_ID" '.[] | select(.id == $sid) | .last_seen' | head -n1)"

    if [ "$STATUS" = "active" ] && [ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" != "null" ]; then
      ok "Sensor registrado, visible como active y con last_seen real"
      break
    fi
  fi

  sleep 2
done

if [ "$STATUS" != "active" ] || [ -z "$LAST_SEEN" ] || [ "$LAST_SEEN" = "null" ]; then
  echo
  echo "---- logs sensor_agent ----"
  (
    cd "$ROOT_DIR"
    docker compose logs --no-color --tail=120 sensor_agent || true
  )
  echo "---------------------------"
  die "El sensor no quedó online con heartbeat real"
fi

cat > "$STATE_FILE" <<EOF
{
  "tenant_id": "$TENANT_ID",
  "tenant_name": "$TENANT_NAME",
  "sensor_id": "$SENSOR_ID",
  "sensor_name": "$SENSOR_NAME",
  "admin_user_id": "$ADMIN_USER_ID",
  "admin_email": "$ADMIN_EMAIL",
  "last_seen": "$LAST_SEEN",
  "config_file": "$CONFIG_FILE",
  "control_plane_url": "$API_BASE_URL",
  "control_plane_internal_url": "$CONTROL_PLANE_INTERNAL_URL",
  "local_control_plane_host_port": "$LOCAL_CONTROL_PLANE_HOST_PORT",
  "local_sensor_ssh_port": "$LOCAL_SENSOR_SSH_PORT",
  "local_sensor_http_port": "$LOCAL_SENSOR_HTTP_PORT",
  "local_sensor_https_port": "$LOCAL_SENSOR_HTTPS_PORT"
}
EOF

cat <<EOF

✅ T29 quickstart local listo

Tenant ID:   $TENANT_ID
Sensor ID:   $SENSOR_ID
Last seen:   $LAST_SEEN
Config file: $CONFIG_FILE
State file:  $STATE_FILE

Pruebas manuales sugeridas:
  curl http://localhost:${LOCAL_SENSOR_HTTP_PORT}/login
  curl http://localhost:${LOCAL_SENSOR_HTTP_PORT}/admin
  ssh demo@localhost -p ${LOCAL_SENSOR_SSH_PORT}

Consulta de sensores:
  curl -H "x-user-id: $ADMIN_USER_ID" "$API_BASE_URL/v1/tenants/$TENANT_ID/sensors"

EOF
