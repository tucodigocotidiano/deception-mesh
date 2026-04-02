#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/deploy/sql"
DST_DIR="$ROOT_DIR/deploy/sql_prod"

if [ ! -d "$SRC_DIR" ]; then
  echo "No existe $SRC_DIR" >&2
  exit 1
fi

mkdir -p "$DST_DIR"
find "$DST_DIR" -maxdepth 1 -type f -name '*.sql' -delete

while IFS= read -r -d '' file; do
  base="$(basename "$file")"
  if [ "$base" = "9999_seed_admin.sql" ]; then
    continue
  fi
  cp "$file" "$DST_DIR/$base"
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.sql' -print0 | sort -z)

echo "SQL de producción preparado en: $DST_DIR"
ls -1 "$DST_DIR"