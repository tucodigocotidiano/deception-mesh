#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.production}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/compose.production.yml}"

require_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "Falta archivo: $path" >&2
    exit 1
  fi
}

require_dir() {
  local path="$1"
  if [ ! -d "$path" ]; then
    echo "Falta directorio: $path" >&2
    exit 1
  fi
}

require_file "$ENV_FILE"
require_file "$COMPOSE_FILE"

if [ ! -d "$ROOT_DIR/deploy/sql_prod" ] || [ -z "$(find "$ROOT_DIR/deploy/sql_prod" -maxdepth 1 -type f -name '*.sql' -print -quit)" ]; then
  echo "==> Preparando SQL de producción"
  bash "$ROOT_DIR/scripts/prepare_sql_prod.sh"
fi

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

SERVICES=("$@")
if [ "${#SERVICES[@]}" -eq 0 ]; then
  if [ -f "$ROOT_DIR/deploy/runtime/sensor.production.toml" ]; then
    SERVICES=(postgres control_plane sensor_agent)
  else
    SERVICES=(postgres control_plane)
  fi
fi

echo "==> Servicios a desplegar: ${SERVICES[*]}"
"${COMPOSE[@]}" pull "${SERVICES[@]}" || true
"${COMPOSE[@]}" up -d "${SERVICES[@]}"

echo
echo "==> Estado del stack"
"${COMPOSE[@]}" ps