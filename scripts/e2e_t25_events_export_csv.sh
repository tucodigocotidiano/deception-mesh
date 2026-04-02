#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_lib.sh"

require_base_deps
ensure_stack
wait_for_http_200 "$API/health" "/health"
wait_for_http_200 "$API/ready" "/ready"

TMP_DIR="$(mktemp -d /tmp/deceptionmesh_t25_export.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ADMIN_LOGIN_JSON="$(login_json "$ADMIN_EMAIL" "$ADMIN_PASSWORD")"
ADMIN_TOKEN="$(json_field "$ADMIN_LOGIN_JSON" '.access_token')"
ADMIN_USER_ID="$(json_field "$ADMIN_LOGIN_JSON" '.user_id')"

[ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ] || die "No se obtuvo token admin"
[ -n "$ADMIN_USER_ID" ] && [ "$ADMIN_USER_ID" != "null" ] || die "No se obtuvo user_id admin"

READONLY_EMAIL="readonly.t25.$(date +%s)@acme.com"
OUTSIDER_EMAIL="outsider.t25.$(date +%s)@acme.com"

READONLY_USER_ID="$(ensure_user "$READONLY_EMAIL")"
OUTSIDER_USER_ID="$(ensure_user "$OUTSIDER_EMAIL")"

READONLY_LOGIN_JSON="$(login_json "$READONLY_EMAIL" "$TEST_DEFAULT_PASSWORD")"
READONLY_TOKEN="$(json_field "$READONLY_LOGIN_JSON" '.access_token')"

OUTSIDER_LOGIN_JSON="$(login_json "$OUTSIDER_EMAIL" "$TEST_DEFAULT_PASSWORD")"
OUTSIDER_TOKEN="$(json_field "$OUTSIDER_LOGIN_JSON" '.access_token')"

[ -n "$READONLY_TOKEN" ] && [ "$READONLY_TOKEN" != "null" ] || die "No se obtuvo token readonly"
[ -n "$OUTSIDER_TOKEN" ] && [ "$OUTSIDER_TOKEN" != "null" ] || die "No se obtuvo token outsider"

TENANT_A="$(create_tenant "Tenant T25 Export A $(date +%s)")"
TENANT_B="$(create_tenant "Tenant T25 Export B $(date +%s)")"

grant_membership "$TENANT_A" "$ADMIN_USER_ID" "admin"
grant_membership "$TENANT_A" "$READONLY_USER_ID" "readonly"
grant_membership "$TENANT_B" "$OUTSIDER_USER_ID" "admin"

SENSOR_A_JSON="$(create_sensor_for_tenant "$ADMIN_TOKEN" "$TENANT_A" "sensor-export-a")"
SENSOR_B_JSON="$(create_sensor_for_tenant "$OUTSIDER_TOKEN" "$TENANT_B" "sensor-export-b")"

SENSOR_A_ID="$(echo "$SENSOR_A_JSON" | jq -r .sensor_id)"
SENSOR_A_TOKEN="$(echo "$SENSOR_A_JSON" | jq -r .sensor_token)"
SENSOR_B_ID="$(echo "$SENSOR_B_JSON" | jq -r .sensor_id)"
SENSOR_B_TOKEN="$(echo "$SENSOR_B_JSON" | jq -r .sensor_token)"

EVENT_HTTP_A_FILE="$TMP_DIR/event_http_a.json"
EVENT_CRITICAL_A_FILE="$TMP_DIR/event_critical_a.json"
EVENT_B_FILE="$TMP_DIR/event_b.json"

EVENT_HTTP_A_ID="$(write_event_json \
  "$EVENT_HTTP_A_FILE" \
  "$TENANT_A" \
  "$SENSOR_A_ID" \
  "http" \
  "198.51.100.31" \
  "41001" \
  "2026-03-29T22:10:01Z" \
  '{"username":null,"ssh_auth_method":null,"http_user_agent":"export-http-a","http_method":"GET","http_path":"/login","decoy_hit":null,"decoy_kind":null}'
)"

EVENT_CRITICAL_A_ID="$(write_event_json \
  "$EVENT_CRITICAL_A_FILE" \
  "$TENANT_A" \
  "$SENSOR_A_ID" \
  "ssh" \
  "198.51.100.32" \
  "41002" \
  "2026-03-29T22:10:02Z" \
  '{"username":"decoy-admin","ssh_auth_method":"password","http_user_agent":null,"http_method":null,"http_path":null,"decoy_hit":true,"decoy_kind":"credential"}'
)"

EVENT_B_ID="$(write_event_json \
  "$EVENT_B_FILE" \
  "$TENANT_B" \
  "$SENSOR_B_ID" \
  "http" \
  "198.51.100.33" \
  "41003" \
  "2026-03-29T22:10:03Z" \
  '{"username":null,"ssh_auth_method":null,"http_user_agent":"export-http-b","http_method":"GET","http_path":"/admin","decoy_hit":null,"decoy_kind":null}'
)"

info "Ingeriendo eventos base"
assert_http_code 201 \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_A_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$EVENT_HTTP_A_FILE"

assert_http_code 201 \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_A_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$EVENT_CRITICAL_A_FILE"

assert_http_code 201 \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_B_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$EVENT_B_FILE"

wait_for_event_present "$TENANT_A" "$EVENT_HTTP_A_ID" "$READONLY_TOKEN" 15 >/dev/null
wait_for_event_present "$TENANT_A" "$EVENT_CRITICAL_A_ID" "$READONLY_TOKEN" 15 >/dev/null
wait_for_event_present "$TENANT_B" "$EVENT_B_ID" "$OUTSIDER_TOKEN" 15 >/dev/null

info "Validando export CSV global por tenant"
CSV_FILE="$TMP_DIR/events.csv"
HEADERS_FILE="$TMP_DIR/events.headers"

HTTP_CODE="$(
  curl -sS \
    -D "$HEADERS_FILE" \
    -o "$CSV_FILE" \
    -w "%{http_code}" \
    "$API/events/export.csv?tenant_id=$TENANT_A" \
    -H "Authorization: Bearer $READONLY_TOKEN"
)"

[ "$HTTP_CODE" = "200" ] || die "Esperaba HTTP 200 en export CSV y obtuve $HTTP_CODE"

grep -qi '^content-type: text/csv' "$HEADERS_FILE" \
  || die "La respuesta no vino con Content-Type text/csv"

grep -qi '^content-disposition: attachment; filename=' "$HEADERS_FILE" \
  || die "La respuesta no vino como descarga adjunta"

python3 - "$CSV_FILE" "$EVENT_HTTP_A_ID" "$EVENT_CRITICAL_A_ID" "$EVENT_B_ID" <<'PY'
import csv
import sys
from pathlib import Path

csv_file = Path(sys.argv[1])
event_http_a = sys.argv[2]
event_critical_a = sys.argv[3]
event_b = sys.argv[4]

rows = list(csv.DictReader(csv_file.open("r", encoding="utf-8", newline="")))
if len(rows) < 2:
    raise SystemExit("El export CSV no devolvió los eventos esperados para tenant A")

required_columns = {
    "event_id",
    "tenant_id",
    "sensor_id",
    "schema_version",
    "service",
    "src_ip",
    "src_port",
    "occurred_at",
    "severity",
    "severity_reason",
    "attempt_count",
    "event_timestamp_rfc3339",
    "username",
    "ssh_auth_method",
    "http_user_agent",
    "http_method",
    "http_path",
    "decoy_hit",
    "decoy_kind",
    "raw_event_json",
}

missing = required_columns.difference(rows[0].keys())
if missing:
    raise SystemExit(f"Faltan columnas en CSV: {sorted(missing)}")

exported_ids = {row["event_id"] for row in rows}
if event_http_a not in exported_ids:
    raise SystemExit("No apareció el evento HTTP del tenant A en el CSV")
if event_critical_a not in exported_ids:
    raise SystemExit("No apareció el evento critical del tenant A en el CSV")
if event_b in exported_ids:
    raise SystemExit("Apareció un evento de tenant B dentro del CSV de tenant A")
PY

info "Validando filtro severity=critical sobre CSV"
CSV_CRITICAL_FILE="$TMP_DIR/events_critical.csv"
HTTP_CODE="$(
  curl -sS \
    -o "$CSV_CRITICAL_FILE" \
    -w "%{http_code}" \
    "$API/events/export.csv?tenant_id=$TENANT_A&severity=critical" \
    -H "Authorization: Bearer $READONLY_TOKEN"
)"

[ "$HTTP_CODE" = "200" ] || die "Esperaba HTTP 200 en export CSV filtered severity y obtuve $HTTP_CODE"

python3 - "$CSV_CRITICAL_FILE" "$EVENT_CRITICAL_A_ID" <<'PY'
import csv
import sys
from pathlib import Path

csv_file = Path(sys.argv[1])
expected_event_id = sys.argv[2]

rows = list(csv.DictReader(csv_file.open("r", encoding="utf-8", newline="")))
if len(rows) != 1:
    raise SystemExit(f"severity=critical debería devolver 1 fila, devolvió {len(rows)}")

row = rows[0]
if row["event_id"] != expected_event_id:
    raise SystemExit("severity=critical no devolvió el evento esperado")
if row["severity"] != "critical":
    raise SystemExit("severity=critical devolvió una fila con severidad distinta")
PY

info "Validando filtros service=http y text=/login sobre CSV"
CSV_HTTP_FILE="$TMP_DIR/events_http.csv"
HTTP_CODE="$(
  curl -sS \
    -o "$CSV_HTTP_FILE" \
    -w "%{http_code}" \
    "$API/events/export.csv?tenant_id=$TENANT_A&service=http&text=/login" \
    -H "Authorization: Bearer $READONLY_TOKEN"
)"

[ "$HTTP_CODE" = "200" ] || die "Esperaba HTTP 200 en export CSV filtered http/text y obtuve $HTTP_CODE"

python3 - "$CSV_HTTP_FILE" "$EVENT_HTTP_A_ID" <<'PY'
import csv
import sys
from pathlib import Path

csv_file = Path(sys.argv[1])
expected_event_id = sys.argv[2]

rows = list(csv.DictReader(csv_file.open("r", encoding="utf-8", newline="")))
if len(rows) != 1:
    raise SystemExit(f"service=http&text=/login debería devolver 1 fila, devolvió {len(rows)}")

row = rows[0]
if row["event_id"] != expected_event_id:
    raise SystemExit("service=http&text=/login no devolvió el evento esperado")
if row["service"] != "http":
    raise SystemExit("service=http devolvió una fila con service distinto")
if row["http_path"] != "/login":
    raise SystemExit("text=/login no devolvió la ruta esperada")
PY

info "Validando aislamiento de tenant sobre export CSV"
assert_http_code 404 \
  -H "Authorization: Bearer $OUTSIDER_TOKEN" \
  "$API/events/export.csv?tenant_id=$TENANT_A"

info "Validando ruta scoped opcional de export CSV"
SCOPED_CSV_FILE="$TMP_DIR/events_scoped.csv"
HTTP_CODE="$(
  curl -sS \
    -o "$SCOPED_CSV_FILE" \
    -w "%{http_code}" \
    "$API/v1/tenants/$TENANT_A/events/export.csv" \
    -H "Authorization: Bearer $READONLY_TOKEN"
)"

[ "$HTTP_CODE" = "200" ] || die "La ruta scoped /v1/tenants/:tenant_id/events/export.csv no respondió 200"

ok "T25 export CSV: OK"