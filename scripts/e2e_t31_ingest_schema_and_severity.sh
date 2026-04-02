#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_lib.sh"

require_base_deps
ensure_stack
wait_for_http_200 "$API/health" "/health"
wait_for_http_200 "$API/ready" "/ready"

TMP_DIR="$(mktemp -d /tmp/deceptionmesh_t31_ingest.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ADMIN_LOGIN_JSON="$(login_json "$ADMIN_EMAIL" "$ADMIN_PASSWORD")"
ADMIN_TOKEN="$(json_field "$ADMIN_LOGIN_JSON" '.access_token')"
ADMIN_USER_ID="$(json_field "$ADMIN_LOGIN_JSON" '.user_id')"

[ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ] || die "No se obtuvo token admin"

TENANT_ID="$(create_tenant "Tenant T31 Ingest $(date +%s)")"
grant_membership "$TENANT_ID" "$ADMIN_USER_ID" "admin"

SENSOR_JSON="$(create_sensor_for_tenant "$ADMIN_TOKEN" "$TENANT_ID" "sensor-ingest-t31")"
SENSOR_ID="$(echo "$SENSOR_JSON" | jq -r .sensor_id)"
SENSOR_TOKEN="$(echo "$SENSOR_JSON" | jq -r .sensor_token)"

[ -n "$SENSOR_TOKEN" ] && [ "$SENSOR_TOKEN" != "null" ] || die "No se obtuvo sensor token"

info "Validando payload inválido => 400"
assert_http_code 400 \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"schema_version":1}'

VALID_HTTP_FILE="$TMP_DIR/valid_http.json"
VALID_HTTP_EVENT_ID="$(write_event_json \
  "$VALID_HTTP_FILE" \
  "$TENANT_ID" \
  "$SENSOR_ID" \
  "http" \
  "198.51.100.50" \
  "41234" \
  "2026-03-29T21:20:01Z" \
  '{"username":null,"ssh_auth_method":null,"http_user_agent":"t31-ingest","http_method":"GET","http_path":"/login","decoy_hit":null,"decoy_kind":null}'
)"

info "Validando token inválido => 401"
assert_http_code 401 \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer dm_sensor_invalid_token" \
  -H "Content-Type: application/json" \
  --data @"$VALID_HTTP_FILE"

info "Validando evento válido => 201"
INGEST_JSON="$(curl -sS -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$VALID_HTTP_FILE")"

assert_json_condition "$INGEST_JSON" '.ingested == true' "El primer ingest no quedó como ingested=true"
assert_json_condition "$INGEST_JSON" '.severity == "low"' "El primer evento debería arrancar en low"

info "Validando idempotencia por event_id => segundo POST no duplica"
SECOND_INGEST_JSON="$(curl -sS -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$VALID_HTTP_FILE")"

assert_json_condition "$SECOND_INGEST_JSON" '.ingested == false' "El segundo ingest debería quedar ingested=false"

info "Generando múltiples intentos para elevar severidad"
for i in 1 2 3 4 5; do
  FILE_I="$TMP_DIR/repeat_$i.json"
  TS="2026-03-29T21:21:0${i}Z"

  write_event_json \
    "$FILE_I" \
    "$TENANT_ID" \
    "$SENSOR_ID" \
    "http" \
    "198.51.100.77" \
    "45000" \
    "$TS" \
    '{"username":null,"ssh_auth_method":null,"http_user_agent":"repeat-ua","http_method":"GET","http_path":"/admin","decoy_hit":null,"decoy_kind":null}' \
    >/dev/null

  assert_http_code 201 \
    -X POST "$API/events/ingest" \
    -H "Authorization: Bearer $SENSOR_TOKEN" \
    -H "Content-Type: application/json" \
    --data @"$FILE_I"
done

REPEATED_EVENTS_JSON="$(curl -sS \
  "$API/v1/tenants/$TENANT_ID/events?src_ip=198.51.100.77&service=http&limit=20" \
  -H "Authorization: Bearer $ADMIN_TOKEN")"

assert_json_condition \
  "$REPEATED_EVENTS_JSON" \
  '(.items | length) >= 5' \
  "No encontré los 5 eventos repetidos"

assert_json_condition \
  "$REPEATED_EVENTS_JSON" \
  'any(.items[]?; .severity == "high")' \
  "Los intentos repetidos no elevaron a high"

assert_json_condition \
  "$REPEATED_EVENTS_JSON" \
  '([.items[]?.attempt_count] | max) >= 5' \
  "No apareció attempt_count esperado"

info "Validando severidad critical por credential decoy"
DECOY_FILE="$TMP_DIR/decoy_ssh.json"
DECOY_EVENT_ID="$(write_event_json \
  "$DECOY_FILE" \
  "$TENANT_ID" \
  "$SENSOR_ID" \
  "ssh" \
  "203.0.113.90" \
  "52222" \
  "2026-03-29T21:22:01Z" \
  '{"username":"decoy-admin","ssh_auth_method":"password","http_user_agent":null,"http_method":null,"http_path":null,"decoy_hit":true,"decoy_kind":"credential"}'
)"

DECOY_INGEST_JSON="$(curl -sS -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$DECOY_FILE")"

assert_json_condition \
  "$DECOY_INGEST_JSON" \
  '.severity == "critical"' \
  "La credencial decoy no elevó a critical"

assert_json_condition \
  "$DECOY_INGEST_JSON" \
  '.severity_reason | contains("decoy_credential_hit")' \
  "No apareció reason de decoy credential"

info "Validando filtros de consulta"
CRITICAL_JSON="$(curl -sS \
  "$API/v1/tenants/$TENANT_ID/events?severity=critical&limit=20" \
  -H "Authorization: Bearer $ADMIN_TOKEN")"

assert_json_condition \
  "$CRITICAL_JSON" \
  'any(.items[]?; .id == "'"$DECOY_EVENT_ID"'")' \
  "El filtro severity=critical no devolvió el evento decoy"

TEXT_JSON="$(curl -sS \
  "$API/v1/tenants/$TENANT_ID/events?text=decoy-admin&limit=20" \
  -H "Authorization: Bearer $ADMIN_TOKEN")"

assert_json_condition \
  "$TEXT_JSON" \
  'any(.items[]?; .id == "'"$DECOY_EVENT_ID"'")' \
  "El filtro text no devolvió el evento decoy"

info "Validando filtro inválido => 400"
assert_http_code 400 \
  "$API/v1/tenants/$TENANT_ID/events?severity=urgent" \
  -H "Authorization: Bearer $ADMIN_TOKEN"

ok "T31 ingest + schema + severidad + filtros: OK"