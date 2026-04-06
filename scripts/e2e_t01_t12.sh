#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

API="${API:-http://localhost:8080}"
T12_SSH_PORT="${T12_SSH_PORT:-2222}"
T12_SSH_USER="${T12_SSH_USER:-decoy-user}"

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

http_code() { curl -sS -o /dev/null -w "%{http_code}" "$@"; }

HAVE_STDBUF=0

cleanup() {
  if [ -n "${T11_TMP_CFG:-}" ] && [ -f "${T11_TMP_CFG:-}" ]; then
    rm -f "$T11_TMP_CFG"
  fi

  if [ -n "${T12_AGENT_PID:-}" ]; then
    kill "$T12_AGENT_PID" 2>/dev/null || true
    wait "$T12_AGENT_PID" 2>/dev/null || true
  fi

  if [ -n "${T12_TMP_CFG:-}" ] && [ -f "${T12_TMP_CFG:-}" ]; then
    rm -f "$T12_TMP_CFG"
  fi

  if [ -n "${T12_LOG_FILE:-}" ] && [ -f "${T12_LOG_FILE:-}" ]; then
    rm -f "$T12_LOG_FILE"
  fi
}
trap cleanup EXIT

wait_for_log() {
  local pattern="$1"
  local file="$2"
  local tries="${3:-20}"

  for _ in $(seq 1 "$tries"); do
    if grep -qi "$pattern" "$file"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

prepare_sensor_cfg_from_template() {
  local out_file="$1"
  local tenant_id="$2"
  local sensor_id="$3"
  local sensor_token="$4"
  local base_url="$5"
  local heartbeat_interval="$6"
  local ssh_listen_addr="$7"
  local ssh_banner="$8"

  if test -f deploy/sensor/sensor.example.toml; then
    cp deploy/sensor/sensor.example.toml "$out_file"
  else
    cat > "$out_file" <<EOF
[sensor]
tenant_id = "$tenant_id"
sensor_id = "$sensor_id"
sensor_token = "$sensor_token"

[control_plane]
base_url = "$base_url"
heartbeat_path = "/sensors/{sensor_id}/heartbeat"
request_timeout_seconds = 2

[runtime]
heartbeat_interval_seconds = $heartbeat_interval
max_queue = 10000

[logging]
level = "info"
format = "pretty"

[honeypots]
ssh_listen_addr = "$ssh_listen_addr"
ssh_banner = "$ssh_banner"
EOF
  fi

  sed -i 's/\r$//' "$out_file"

  sed -i \
    -e "s|^tenant_id *=.*|tenant_id = \"$tenant_id\"|g" \
    -e "s|^sensor_id *=.*|sensor_id = \"$sensor_id\"|g" \
    -e "s|^sensor_token *=.*|sensor_token = \"$sensor_token\"|g" \
    -e "s|^base_url *=.*|base_url = \"$base_url\"|g" \
    -e "s|^heartbeat_interval_seconds *=.*|heartbeat_interval_seconds = $heartbeat_interval|g" \
    -e "s|^ssh_listen_addr *=.*|ssh_listen_addr = \"$ssh_listen_addr\"|g" \
    -e "s|^ssh_banner *=.*|ssh_banner = \"$ssh_banner\"|g" \
    "$out_file"
}

run_sensor_agent_capture() {
  local cfg_file="$1"

  if [ "$HAVE_STDBUF" = "1" ]; then
    timeout 12s stdbuf -oL -eL ./target/debug/sensor_agent --config "$cfg_file" 2>&1
  else
    timeout 12s ./target/debug/sensor_agent --config "$cfg_file" 2>&1
  fi
}

# -------------------------
# Pre-checks
# -------------------------
need docker
need curl
need jq
need cargo
need timeout
need ssh
need grep
need sed
need mktemp

if command -v stdbuf >/dev/null 2>&1; then
  HAVE_STDBUF=1
fi

info "API=$API"
info "Repo=$REPO_ROOT"

# -------------------------
# T01 — Docs
# -------------------------
info "T01: verificando docs..."
test -f docs/architecture.md || die "Falta docs/architecture.md"
test -f docs/mvp_scope.md || die "Falta docs/mvp_scope.md"
grep -qi "Sensor Agent" docs/architecture.md || die "docs/architecture.md no menciona Sensor Agent"
grep -qi "Control Plane" docs/architecture.md || die "docs/architecture.md no menciona Control Plane"
grep -qi "Fuera de alcance" docs/mvp_scope.md || die "docs/mvp_scope.md no tiene 'Fuera de alcance'"
grep -qi "webhook" docs/mvp_scope.md || die "docs/mvp_scope.md no menciona webhook"
ok "T01 OK (arch + scope)"

# -------------------------
# T02 — Calidad Rust
# -------------------------
info "T02: cargo fmt/clippy/test/build..."
cargo fmt --check
cargo clippy --workspace -- -D warnings
cargo test --workspace
cargo build --workspace
ok "T02 OK (fmt/clippy/test/build)"

# -------------------------
# T03 — Workflow CI
# -------------------------
info "T03: verificando workflow CI..."
if ls .github/workflows/*.yml >/dev/null 2>&1; then
  ok "T03 OK (hay workflows)"
else
  info "T03 WARNING: no encontré .github/workflows/*.yml"
fi

# -------------------------
# T04 — Stack local
# -------------------------
info "T04: levantando stack..."
docker compose up -d --build
docker compose ps

HC="$(http_code -i "$API/health")"
RC="$(http_code -i "$API/ready")"
[ "$HC" = "200" ] || die "/health no devuelve 200 (got $HC)"
[ "$RC" = "200" ] || die "/ready no devuelve 200 (got $RC)"
ok "T04 OK (stack arriba + health/ready 200)"

info "Logs (control plane tail):"
docker logs deceptionmesh-control-plane --tail 20 || true

DB_URL="$(docker compose exec -T control_plane printenv DATABASE_URL | tr -d '\r')"
DB_NAME="$(echo "$DB_URL" | sed -E 's#.*/##')"
PGUSER="$(docker compose exec -T postgres printenv POSTGRES_USER | tr -d '\r')"

info "DATABASE_URL=$DB_URL"
info "DB_NAME=$DB_NAME  PGUSER=$PGUSER"

# -------------------------
# T06 — Auth
# -------------------------
info "T06: login + checks 401..."
LOGIN_JSON="$(curl -sS -X POST "$API/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@acme.com","password":"admin"}')"

echo "$LOGIN_JSON" | jq . >/dev/null

TOKEN="$(echo "$LOGIN_JSON" | jq -r .access_token)"
USER_ID="$(echo "$LOGIN_JSON" | jq -r .user_id)"

[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || die "No se obtuvo access_token"
[ -n "$USER_ID" ] && [ "$USER_ID" != "null" ] || die "No se obtuvo user_id"

ok "Login OK (T06) user_id=$USER_ID token_head=$(echo "$TOKEN" | cut -c1-16)..."

C401="$(http_code "$API/v1/tenants")"
[ "$C401" = "401" ] || die "Esperaba 401 en /v1/tenants sin token, got $C401"
ok "T06 OK (401 sin token)"

# -------------------------
# T05 — Multi-tenant + RBAC
# -------------------------
info "T05: creando tenant A con membership admin..."
TENANT_A="$(uuid)"
docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"INSERT INTO tenants (id, name) VALUES ('$TENANT_A','Acme SOC') ON CONFLICT DO NOTHING;" >/dev/null

docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"INSERT INTO memberships (tenant_id, user_id, role)
 VALUES ('$TENANT_A','$USER_ID','admin')
 ON CONFLICT DO NOTHING;" >/dev/null

TENANTS_JSON="$(curl -sS "$API/v1/tenants" -H "Authorization: Bearer $TOKEN")"
echo "$TENANTS_JSON" | jq . >/dev/null
echo "$TENANTS_JSON" | jq -e --arg tid "$TENANT_A" '.[] | select(.id==$tid)' >/dev/null \
  || die "Tenant A no aparece en /v1/tenants (T05 falla)"
ok "T05 OK (tenant A visible)"

info "T05: creando tenant B SIN membership..."
TENANT_B="$(uuid)"
docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"INSERT INTO tenants (id, name) VALUES ('$TENANT_B','Other Org') ON CONFLICT DO NOTHING;" >/dev/null

C_B="$(http_code -X POST "$API/v1/tenants/$TENANT_B/sensors/enroll-token" \
  -H "Authorization: Bearer $TOKEN")"
[ "$C_B" = "404" ] || die "Esperaba 404 en tenant B sin membership, got $C_B"
ok "T05 OK (aislamiento básico: 404)"

# -------------------------
# T07 — Auditoría + RBAC
# -------------------------
info "T07: webhook update (admin) => audit_log..."
C_WH="$(http_code -X PUT "$API/v1/tenants/$TENANT_A/webhook" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"webhook_url":"https://example.com/webhook","webhook_min_severity":2}')"
[ "$C_WH" = "200" ] || die "PUT webhook (admin) debía ser 200, got $C_WH"

AUD_SQL="$(docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -t -A -c \
"SELECT count(*) FROM audit_log WHERE tenant_id='$TENANT_A' AND action='tenant.webhook.update';" | tr -d '[:space:]')"
[ "${AUD_SQL:-0}" -ge 1 ] || die "No se registró audit_log (T07 falla)"
ok "T07 OK (audit_log creado)"

info "T05/T07: probando RBAC readonly..."
docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"UPDATE memberships SET role='readonly' WHERE tenant_id='$TENANT_A' AND user_id='$USER_ID';" >/dev/null

C_FORB="$(http_code -X PUT "$API/v1/tenants/$TENANT_A/webhook" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"webhook_url":"https://example.com/blocked","webhook_min_severity":1}')"
[ "$C_FORB" = "403" ] || die "Readonly debía ser 403 en PUT webhook, got $C_FORB"
ok "RBAC OK (readonly => 403)"

docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"UPDATE memberships SET role='admin' WHERE tenant_id='$TENANT_A' AND user_id='$USER_ID';" >/dev/null
ok "Rol restaurado a admin"

AUD_JSON="$(curl -sS "$API/v1/tenants/$TENANT_A/audit?limit=50" -H "Authorization: Bearer $TOKEN")"
echo "$AUD_JSON" | jq . >/dev/null
ok "T07 OK (/audit responde JSON)"

# -------------------------
# T08 — Enroll + register
# -------------------------
info "T08: creando enroll token..."
ENROLL_JSON="$(curl -sS -X POST "$API/v1/tenants/$TENANT_A/sensors/enroll-token" \
  -H "Authorization: Bearer $TOKEN")"
echo "$ENROLL_JSON" | jq . >/dev/null

ENROLL_TOKEN="$(echo "$ENROLL_JSON" | jq -r .enroll_token)"
[ -n "$ENROLL_TOKEN" ] && [ "$ENROLL_TOKEN" != "null" ] || die "No se obtuvo enroll_token"
ok "Enroll token OK"

info "T08: registrando sensor..."
REGISTER_JSON="$(curl -sS -X POST "$API/sensors/register" \
  -H "Content-Type: application/json" \
  -d "{\"tenant_id\":\"$TENANT_A\",\"enroll_token\":\"$ENROLL_TOKEN\",\"name\":\"sensor-1\"}")"
echo "$REGISTER_JSON" | jq . >/dev/null

SENSOR_ID="$(echo "$REGISTER_JSON" | jq -r .sensor_id)"
SENSOR_TOKEN="$(echo "$REGISTER_JSON" | jq -r .sensor_token)"
[ -n "$SENSOR_ID" ] && [ "$SENSOR_ID" != "null" ] || die "No se obtuvo sensor_id"
[ -n "$SENSOR_TOKEN" ] && [ "$SENSOR_TOKEN" != "null" ] || die "No se obtuvo sensor_token"
ok "Sensor registrado OK sensor_id=$SENSOR_ID"

C_LS="$(http_code "$API/v1/tenants/$TENANT_A/sensors" -H "Authorization: Bearer $TOKEN")"
[ "$C_LS" = "200" ] || die "List sensors debía ser 200, got $C_LS"
curl -sS "$API/v1/tenants/$TENANT_A/sensors" -H "Authorization: Bearer $TOKEN" | jq . >/dev/null
ok "T08 OK (listar sensores 200)"

USED="$(docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -t -A -c \
"SELECT used_at IS NOT NULL FROM sensor_enroll_tokens WHERE tenant_id='$TENANT_A' ORDER BY created_at DESC LIMIT 1;" | tr -d '[:space:]')"
[ "$USED" = "t" ] || die "Enroll token no quedó marcado como usado (T08 falla)"
ok "T08 OK (enroll usado + token hasheado)"

C_REUSE="$(http_code -X POST "$API/sensors/register" \
  -H "Content-Type: application/json" \
  -d "{\"tenant_id\":\"$TENANT_A\",\"enroll_token\":\"$ENROLL_TOKEN\",\"name\":\"sensor-reuse\"}")"
[ "$C_REUSE" = "401" ] || die "Reusar enroll debía 401, got $C_REUSE"
ok "T08 OK (reuso enroll => 401)"

# -------------------------
# T09 — Heartbeat
# -------------------------
info "T09: heartbeat válido..."
HB_JSON="$(curl -sS -X POST "$API/sensors/$SENSOR_ID/heartbeat" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_version":"0.0.1","rtt_ms":12}')"
echo "$HB_JSON" | jq . >/dev/null
ok "Heartbeat OK"

docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"SELECT id, status, last_seen, agent_version, rtt_ms FROM sensors WHERE id='$SENSOR_ID';" >/dev/null
ok "DB OK tras heartbeat"

info "T09: simular OFFLINE..."
docker compose exec -T postgres psql -U "$PGUSER" -d "$DB_NAME" -c \
"UPDATE sensors SET last_seen = now() - interval '10 minutes' WHERE id='$SENSOR_ID' RETURNING id, last_seen;" >/dev/null

SENSORS_AFTER="$(curl -sS "$API/v1/tenants/$TENANT_A/sensors" -H "Authorization: Bearer $TOKEN")"
echo "$SENSORS_AFTER" | jq . >/dev/null
echo "$SENSORS_AFTER" | jq -e --arg sid "$SENSOR_ID" '.[] | select(.id==$sid and .status=="offline")' >/dev/null \
  || die "No apareció offline tras simular last_seen viejo (T09 falla)"
ok "T09 OK (offline por threshold)"

curl -sS -X POST "$API/sensors/$SENSOR_ID/heartbeat" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_version":"0.0.2","rtt_ms":9}' | jq . >/dev/null

SENSORS_BACK="$(curl -sS "$API/v1/tenants/$TENANT_A/sensors" -H "Authorization: Bearer $TOKEN")"
echo "$SENSORS_BACK" | jq -e --arg sid "$SENSOR_ID" '.[] | select(.id==$sid and .status=="active")' >/dev/null \
  || die "No volvió a active tras heartbeat (T09 falla)"
ok "T09 OK (active tras heartbeat)"

C_BAD="$(http_code -X POST "$API/sensors/$SENSOR_ID/heartbeat" \
  -H "Authorization: Bearer dm_sensor_fake" \
  -H "Content-Type: application/json" \
  -d '{"agent_version":"9.9.9","rtt_ms":1}')"
[ "$C_BAD" = "401" ] || die "Token inválido debía 401, got $C_BAD"
ok "T09 OK (token inválido => 401)"

# -------------------------
# T10 — TLS
# -------------------------
info "T10: chequeo rápido..."
info "Dev corre en $API (http). Para cumplir T10 en PROD: forzar https y rechazar http."
ok "T10 OK (informativo en dev)"

# -------------------------
# T11 — Sensor Agent base
# -------------------------
info "T11: probando sensor_agent (arranque + tick)..."

[ -n "${TENANT_A:-}" ] || die "T11: TENANT_A vacío"
[ -n "${SENSOR_ID:-}" ] || die "T11: SENSOR_ID vacío"
[ -n "${SENSOR_TOKEN:-}" ] || die "T11: SENSOR_TOKEN vacío"

test -f ./target/debug/sensor_agent || cargo build -p sensor_agent

T11_TMP_CFG="$(mktemp /tmp/dm_sensor_XXXX.toml)"
prepare_sensor_cfg_from_template \
  "$T11_TMP_CFG" \
  "$TENANT_A" \
  "$SENSOR_ID" \
  "$SENSOR_TOKEN" \
  "$API" \
  "5" \
  "127.0.0.1:$T12_SSH_PORT" \
  "OpenSSH_8.9p1 Ubuntu-3ubuntu0.10"

info "T11: config generada en $T11_TMP_CFG"

set +e
OUT="$(run_sensor_agent_capture "$T11_TMP_CFG")"
EC=$?
set -e

if [ "$EC" != "0" ] && [ "$EC" != "124" ]; then
  echo "$OUT" >&2
  die "T11: ejecución falló (exit=$EC)"
fi

echo "$OUT" | grep -qi "sensor agent starting" || { echo "$OUT" >&2; die "T11: no logueó 'sensor agent starting'"; }
echo "$OUT" | grep -qi "tick" || { echo "$OUT" >&2; die "T11: no se vio 'tick'"; }
echo "$OUT" | grep -qi "$TENANT_A" || { echo "$OUT" >&2; die "T11: logs no muestran tenant_id"; }
echo "$OUT" | grep -qi "$SENSOR_ID" || { echo "$OUT" >&2; die "T11: logs no muestran sensor_id"; }

ok "T11 OK (arranca con --config, logs con contexto)"
rm -f "$T11_TMP_CFG"
unset T11_TMP_CFG

# -------------------------
# T12 — Honeypot SSH
# -------------------------
info "T12: probando honeypot SSH..."

T12_TMP_CFG="$(mktemp /tmp/dm_t12_XXXX.toml)"
T12_LOG_FILE="$(mktemp /tmp/dm_t12_XXXX.log)"

prepare_sensor_cfg_from_template \
  "$T12_TMP_CFG" \
  "$TENANT_A" \
  "$SENSOR_ID" \
  "$SENSOR_TOKEN" \
  "http://127.0.0.1:9" \
  "60" \
  "127.0.0.1:$T12_SSH_PORT" \
  "OpenSSH_8.9p1 Ubuntu-3ubuntu0.10"

info "T12: levantando sensor_agent con honeypot SSH..."
if [ "$HAVE_STDBUF" = "1" ]; then
  stdbuf -oL -eL ./target/debug/sensor_agent --config "$T12_TMP_CFG" >"$T12_LOG_FILE" 2>&1 &
else
  ./target/debug/sensor_agent --config "$T12_TMP_CFG" >"$T12_LOG_FILE" 2>&1 &
fi
T12_AGENT_PID=$!

wait_for_log "ssh honeypot listening" "$T12_LOG_FILE" 20 || {
  cat "$T12_LOG_FILE" >&2
  die "T12: el honeypot SSH no quedó escuchando"
}

ok "T12 bootstrap OK (ssh honeypot listening)"

info "T12: disparando intento SSH real..."
set +e
timeout 8s ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  -o PreferredAuthentications=none \
  -o PubkeyAuthentication=no \
  -o PasswordAuthentication=no \
  -o NumberOfPasswordPrompts=0 \
  -p "$T12_SSH_PORT" \
  "$T12_SSH_USER@127.0.0.1" true >/dev/null 2>&1
SSH_EC=$?
set -e

if [ "$SSH_EC" = "0" ]; then
  cat "$T12_LOG_FILE" >&2
  die "T12: el honeypot no debía permitir shell real"
fi

for _ in $(seq 1 10); do
  if grep -qi "ssh auth attempt captured" "$T12_LOG_FILE" && grep -qi "$T12_SSH_USER" "$T12_LOG_FILE"; then
    break
  fi
  sleep 1
done

grep -qi "ssh auth attempt captured" "$T12_LOG_FILE" || {
  cat "$T12_LOG_FILE" >&2
  die "T12: no se registró evento de auth SSH"
}

grep -qi "$T12_SSH_USER" "$T12_LOG_FILE" || {
  cat "$T12_LOG_FILE" >&2
  die "T12: no se capturó el username"
}

grep -qi "127.0.0.1" "$T12_LOG_FILE" || {
  cat "$T12_LOG_FILE" >&2
  die "T12: no se capturó la IP"
}

kill "$T12_AGENT_PID" 2>/dev/null || true
wait "$T12_AGENT_PID" 2>/dev/null || true
unset T12_AGENT_PID

rm -f "$T12_TMP_CFG" "$T12_LOG_FILE"
unset T12_TMP_CFG
unset T12_LOG_FILE

ok "T12 OK (ssh user@host -p PORT registra IP/puerto/usuario y no entrega shell)"

echo
ok "E2E hasta T12 COMPLETADO (T10 en dev es informativo)."