#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.production}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/compose.production.yml}"

usage() {
  echo "Uso: $0 <admin_email> <admin_password> <tenant_name>" >&2
  exit 1
}

[ "$#" -eq 3 ] || usage

ADMIN_EMAIL="$1"
ADMIN_PASSWORD="$2"
TENANT_NAME="$3"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Falta comando requerido: $1" >&2
    exit 1
  }
}

require_cmd docker
require_cmd python3

if [ ! -f "$ENV_FILE" ]; then
  echo "Falta $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

ADMIN_EMAIL_SQL="$(sql_escape "$ADMIN_EMAIL")"
TENANT_NAME_SQL="$(sql_escape "$TENANT_NAME")"

echo "==> Levantando postgres y control_plane"
"${COMPOSE[@]}" up -d postgres control_plane

echo "==> Esperando health del control_plane"
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${CONTROL_PLANE_HOST_PORT:-18080}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

curl -fsS "http://127.0.0.1:${CONTROL_PLANE_HOST_PORT:-18080}/health" >/dev/null 2>&1 || {
  echo "control_plane no respondió health" >&2
  exit 1
}

echo "==> Generando hash Argon2 para el admin"
PASSWORD_HASH="$("${COMPOSE[@]}" run --rm --no-deps control_plane /usr/local/bin/hash_password --password "$ADMIN_PASSWORD" | tr -d '\r')"
PASSWORD_HASH_SQL="$(sql_escape "$PASSWORD_HASH")"

mapfile -t IDS < <(python3 - <<'PY'
import uuid
print(uuid.uuid4())
print(uuid.uuid4())
PY
)

USER_ID="${IDS[0]}"
TENANT_ID="${IDS[1]}"

USER_ID_RESULT="$("${COMPOSE[@]}" exec -T postgres psql \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  -At \
  -v ON_ERROR_STOP=1 <<SQL
WITH upsert_user AS (
  INSERT INTO users (id, email, password_hash)
  VALUES ('$USER_ID', '$ADMIN_EMAIL_SQL', '$PASSWORD_HASH_SQL')
  ON CONFLICT (email)
  DO UPDATE SET password_hash = EXCLUDED.password_hash
  RETURNING id
),
resolved_user AS (
  SELECT id FROM upsert_user
  UNION
  SELECT id FROM users WHERE email = '$ADMIN_EMAIL_SQL'
  LIMIT 1
)
SELECT id FROM resolved_user LIMIT 1;
SQL
)"

USER_ID_RESULT="$(printf "%s" "$USER_ID_RESULT" | tr -d '\r\n')"

"${COMPOSE[@]}" exec -T postgres psql \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  -v ON_ERROR_STOP=1 <<SQL
INSERT INTO tenants (id, name)
VALUES ('$TENANT_ID', '$TENANT_NAME_SQL');

INSERT INTO memberships (tenant_id, user_id, role)
VALUES ('$TENANT_ID', '$USER_ID_RESULT', 'admin'::role_kind)
ON CONFLICT (tenant_id, user_id)
DO UPDATE SET role = 'admin'::role_kind;
SQL

echo
echo "✅ Admin bootstrap listo"
echo "Admin email: $ADMIN_EMAIL"
echo "User ID:     $USER_ID_RESULT"
echo "Tenant ID:   $TENANT_ID"
echo
echo "Siguiente paso:"
echo "bash scripts/register_production_sensor.sh \"$ADMIN_EMAIL\" '<PASSWORD>' \"$TENANT_ID\" 'sensor-vps-01'"