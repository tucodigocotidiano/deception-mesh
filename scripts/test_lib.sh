#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${API:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@acme.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

DM_FORCE_BUILD="${DM_FORCE_BUILD:-0}"
DM_SKIP_STACK_BOOT="${DM_SKIP_STACK_BOOT:-0}"

WAIT_HTTP_SECONDS="${WAIT_HTTP_SECONDS:-30}"

TEST_DEFAULT_PASSWORD="${TEST_DEFAULT_PASSWORD:-admin}"

if [ -z "${TEST_PASSWORD_HASH+x}" ]; then
  TEST_PASSWORD_HASH='$argon2id$v=19$m=65536,t=3,p=4$G8kwoHO+KUG5dB+H1eHzow$HHcVL+54KcBTvzEFDUMMVgYHRJrJ4IhTLf7Q1oqs4dw'
fi

DB_NAME=""
PGUSER=""

ok()   { echo -e "✅ $*"; }
info() { echo -e "ℹ️  $*"; }
warn() { echo -e "⚠️  $*"; }
die()  { echo -e "❌ $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Falta dependencia: $1"
}

require_base_deps() {
  need docker
  need curl
  need jq
  need python3
  need cargo
}

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

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

sql_quote() {
  printf "'%s'" "$(sql_escape "$1")"
}

http_code() {
  curl -sS -o /dev/null -w "%{http_code}" "$@" || true
}

api_is_healthy() {
  [ "$(http_code "$API/health")" = "200" ]
}

wait_for_http_200() {
  local url="$1"
  local name="$2"

  for _ in $(seq 1 "$WAIT_HTTP_SECONDS"); do
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

ensure_stack() {
  if [ "$DM_SKIP_STACK_BOOT" = "1" ]; then
    info "DM_SKIP_STACK_BOOT=1, no tocaré docker compose"
    return 0
  fi

  if api_is_healthy; then
    ok "Reutilizando stack ya levantado"
    return 0
  fi

  info "Intentando levantar stack base"

  if [ "$DM_FORCE_BUILD" = "1" ]; then
    if docker compose up -d --build >/dev/null; then
      return 0
    fi

    warn "Falló el build; intentaré reutilizar lo que ya esté construido"

    if docker compose up -d --no-build >/dev/null; then
      return 0
    fi

    if api_is_healthy; then
      warn "El API quedó arriba pese al fallo de build; continúo"
      return 0
    fi

    die "No pude levantar el stack con build. Si ves timeout contra Docker Hub, el problema es de red/DNS y no del código."
  fi

  if docker compose up -d --no-build >/dev/null; then
    return 0
  fi

  warn "No se pudo levantar sin build. Intentaré build como último recurso"

  if docker compose up -d --build >/dev/null; then
    return 0
  fi

  if api_is_healthy; then
    warn "El API ya estaba arriba; continúo"
    return 0
  fi

  die "No pude levantar el stack. Revisa Docker, DNS o salida a Docker Hub."
}

discover_db_env() {
  if [ -n "${DB_NAME:-}" ] && [ -n "${PGUSER:-}" ]; then
    return 0
  fi

  DB_NAME="$(docker compose exec -T postgres printenv POSTGRES_DB | tr -d '\r')"
  PGUSER="$(docker compose exec -T postgres printenv POSTGRES_USER | tr -d '\r')"

  [ -n "$DB_NAME" ] || die "No pude descubrir POSTGRES_DB"
  [ -n "$PGUSER" ] || die "No pude descubrir POSTGRES_USER"

  export DB_NAME PGUSER
}

psql_exec() {
  discover_db_env
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$DB_NAME" -c "$1" >/dev/null
}

psql_query() {
  discover_db_env
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$DB_NAME" -At -c "$1" | tr -d '\r'
}

login_json() {
  local email="${1:-$ADMIN_EMAIL}"
  local password="${2:-$ADMIN_PASSWORD}"

  curl -sS -X POST "$API/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}"
}

json_field() {
  local json="$1"
  local jq_expr="$2"
  echo "$json" | jq -r "$jq_expr"
}

assert_http_code() {
  local expected="$1"
  shift

  local code
  code="$(http_code "$@")"

  [ "$code" = "$expected" ] || die "Esperaba HTTP $expected y obtuve $code"
}

assert_json_condition() {
  local json="$1"
  local jq_expr="$2"
  local message="$3"

  echo "$json" | jq -e "$jq_expr" >/dev/null 2>&1 || die "$message"
}

create_user_if_missing() {
  local email="$1"
  local password_hash="${2:-$TEST_PASSWORD_HASH}"

  psql_exec "
    INSERT INTO users (email, password_hash)
    VALUES ($(sql_quote "$email"), $(sql_quote "$password_hash"))
    ON CONFLICT (email) DO NOTHING;
  "
}

user_id_by_email() {
  local email="$1"
  psql_query "SELECT id::text FROM users WHERE email = $(sql_quote "$email") LIMIT 1;"
}

ensure_user() {
  local email="$1"
  create_user_if_missing "$email"
  user_id_by_email "$email"
}

create_tenant() {
  local name="${1:-Tenant $(date +%s)}"
  local tenant_id
  tenant_id="$(uuid)"

  psql_exec "
    INSERT INTO tenants (id, name)
    VALUES ('$tenant_id', $(sql_quote "$name"))
    ON CONFLICT DO NOTHING;
  "

  echo "$tenant_id"
}

grant_membership() {
  local tenant_id="$1"
  local user_id="$2"
  local role="$3"

  psql_exec "
    INSERT INTO memberships (tenant_id, user_id, role)
    VALUES ('$tenant_id', '$user_id', '$role')
    ON CONFLICT (tenant_id, user_id)
    DO UPDATE SET role = EXCLUDED.role;
  "
}

create_sensor_for_tenant() {
  local auth_token="$1"
  local tenant_id="$2"
  local sensor_name="${3:-sensor-$(date +%s)}"

  local enroll_json
  enroll_json="$(curl -sS -X POST "$API/v1/tenants/$tenant_id/sensors/enroll-token" \
    -H "Authorization: Bearer $auth_token")"

  local enroll_token
  enroll_token="$(echo "$enroll_json" | jq -r .enroll_token)"
  [ -n "$enroll_token" ] && [ "$enroll_token" != "null" ] || die "No se obtuvo enroll_token"

  local register_json
  register_json="$(curl -sS -X POST "$API/sensors/register" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"$tenant_id\",\"enroll_token\":\"$enroll_token\",\"name\":\"$sensor_name\"}")"

  local sensor_id
  local sensor_token
  sensor_id="$(echo "$register_json" | jq -r .sensor_id)"
  sensor_token="$(echo "$register_json" | jq -r .sensor_token)"

  [ -n "$sensor_id" ] && [ "$sensor_id" != "null" ] || die "No se obtuvo sensor_id"
  [ -n "$sensor_token" ] && [ "$sensor_token" != "null" ] || die "No se obtuvo sensor_token"

  printf '%s' "$register_json"
}

write_event_json() {
  local outfile="$1"
  local tenant_id="$2"
  local sensor_id="$3"
  local service="$4"
  local src_ip="$5"
  local src_port="$6"
  local timestamp_rfc3339="$7"
  local evidence_json="$8"
  local event_id="${9:-}"

  python3 - "$outfile" "$tenant_id" "$sensor_id" "$service" "$src_ip" "$src_port" "$timestamp_rfc3339" "$evidence_json" "$event_id" <<'PY'
import json
import sys
import uuid
from pathlib import Path

outfile = Path(sys.argv[1])
tenant_id = sys.argv[2]
sensor_id = sys.argv[3]
service = sys.argv[4]
src_ip = sys.argv[5]
src_port = int(sys.argv[6])
timestamp_rfc3339 = sys.argv[7]
evidence = json.loads(sys.argv[8])
event_id = sys.argv[9].strip() or str(uuid.uuid4())

payload = {
    "schema_version": 1,
    "event_id": event_id,
    "tenant_id": tenant_id,
    "sensor_id": sensor_id,
    "service": service,
    "src_ip": src_ip,
    "src_port": src_port,
    "timestamp_rfc3339": timestamp_rfc3339,
    "evidence": evidence,
}

outfile.write_text(json.dumps(payload), encoding="utf-8")
print(event_id)
PY
}

wait_for_event_present() {
  local tenant_id="$1"
  local event_id="$2"
  local auth_token="$3"
  local timeout_seconds="${4:-15}"

  local started_at
  started_at="$(date +%s)"

  while true; do
    local payload
    payload="$(curl -sS "$API/v1/tenants/$tenant_id/events?limit=100" \
      -H "Authorization: Bearer $auth_token")"

    if echo "$payload" | jq -e --arg event_id "$event_id" 'any(.items[]?; .id == $event_id)' >/dev/null 2>&1; then
      printf '%s' "$payload"
      return 0
    fi

    if [ $(( $(date +%s) - started_at )) -gt "$timeout_seconds" ]; then
      echo "$payload" >&2
      die "El evento $event_id no apareció en el tenant $tenant_id"
    fi

    sleep 1
  done
}

wait_for_delivery_status() {
  local tenant_id="$1"
  local event_id="$2"
  local desired_status="$3"
  local timeout_seconds="${4:-40}"
  local auth_token="$5"

  local started_at
  started_at="$(date +%s)"

  while true; do
    local payload
    payload="$(curl -sS \
      "$API/v1/tenants/$tenant_id/webhook-deliveries?event_id=$event_id&limit=20" \
      -H "Authorization: Bearer $auth_token")"

    if echo "$payload" | jq -e --arg desired "$desired_status" '.[0].status == $desired' >/dev/null 2>&1; then
      printf '%s' "$payload"
      return 0
    fi

    if [ $(( $(date +%s) - started_at )) -gt "$timeout_seconds" ]; then
      echo "$payload" >&2
      die "La entrega de webhook para $event_id no llegó a estado '$desired_status'"
    fi

    sleep 1
  done
}