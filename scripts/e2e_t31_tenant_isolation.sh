#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_lib.sh"

require_base_deps
ensure_stack
wait_for_http_200 "$API/health" "/health"
wait_for_http_200 "$API/ready" "/ready"

TMP_DIR="$(mktemp -d /tmp/deceptionmesh_t31_tenants.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

USER_A_EMAIL="tenanta.t31.$(date +%s)@acme.com"
USER_B_EMAIL="tenantb.t31.$(date +%s)@acme.com"

USER_A_ID="$(ensure_user "$USER_A_EMAIL")"
USER_B_ID="$(ensure_user "$USER_B_EMAIL")"

USER_A_TOKEN="$(json_field "$(login_json "$USER_A_EMAIL" "$TEST_DEFAULT_PASSWORD")" '.access_token')"
USER_B_TOKEN="$(json_field "$(login_json "$USER_B_EMAIL" "$TEST_DEFAULT_PASSWORD")" '.access_token')"

[ -n "$USER_A_TOKEN" ] && [ "$USER_A_TOKEN" != "null" ] || die "No se obtuvo token usuario A"
[ -n "$USER_B_TOKEN" ] && [ "$USER_B_TOKEN" != "null" ] || die "No se obtuvo token usuario B"

TENANT_A="$(create_tenant "Tenant A T31 $(date +%s)")"
TENANT_B="$(create_tenant "Tenant B T31 $(date +%s)")"

grant_membership "$TENANT_A" "$USER_A_ID" "admin"
grant_membership "$TENANT_B" "$USER_B_ID" "admin"

SENSOR_A_JSON="$(create_sensor_for_tenant "$USER_A_TOKEN" "$TENANT_A" "sensor-a-t31")"
SENSOR_B_JSON="$(create_sensor_for_tenant "$USER_B_TOKEN" "$TENANT_B" "sensor-b-t31")"

SENSOR_A_ID="$(echo "$SENSOR_A_JSON" | jq -r .sensor_id)"
SENSOR_A_TOKEN="$(echo "$SENSOR_A_JSON" | jq -r .sensor_token)"
SENSOR_B_ID="$(echo "$SENSOR_B_JSON" | jq -r .sensor_id)"
SENSOR_B_TOKEN="$(echo "$SENSOR_B_JSON" | jq -r .sensor_token)"

EVENT_A_FILE="$TMP_DIR/event_a.json"
EVENT_B_FILE="$TMP_DIR/event_b.json"

EVENT_A_ID="$(write_event_json \
  "$EVENT_A_FILE" \
  "$TENANT_A" \
  "$SENSOR_A_ID" \
  "http" \
  "198.51.100.10" \
  "40123" \
  "2026-03-29T21:10:01Z" \
  '{"username":null,"ssh_auth_method":null,"http_user_agent":"tenant-a","http_method":"GET","http_path":"/login","decoy_hit":null,"decoy_kind":null}'
)"

EVENT_B_ID="$(write_event_json \
  "$EVENT_B_FILE" \
  "$TENANT_B" \
  "$SENSOR_B_ID" \
  "http" \
  "198.51.100.11" \
  "40124" \
  "2026-03-29T21:10:02Z" \
  '{"username":null,"ssh_auth_method":null,"http_user_agent":"tenant-b","http_method":"GET","http_path":"/admin","decoy_hit":null,"decoy_kind":null}'
)"

assert_http_code 201 \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_A_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$EVENT_A_FILE"

assert_http_code 201 \
  -X POST "$API/events/ingest" \
  -H "Authorization: Bearer $SENSOR_B_TOKEN" \
  -H "Content-Type: application/json" \
  --data @"$EVENT_B_FILE"

wait_for_event_present "$TENANT_A" "$EVENT_A_ID" "$USER_A_TOKEN" 15 >/dev/null
wait_for_event_present "$TENANT_B" "$EVENT_B_ID" "$USER_B_TOKEN" 15 >/dev/null

info "Validando que /v1/tenants devuelve solo el tenant propio"
TENANTS_A_JSON="$(curl -sS "$API/v1/tenants" -H "Authorization: Bearer $USER_A_TOKEN")"
TENANTS_B_JSON="$(curl -sS "$API/v1/tenants" -H "Authorization: Bearer $USER_B_TOKEN")"

assert_json_condition "$TENANTS_A_JSON" 'any(.[]; .id == "'"$TENANT_A"'")' "Usuario A no ve su tenant"
assert_json_condition "$TENANTS_A_JSON" 'all(.[]; .id != "'"$TENANT_B"'")' "Usuario A ve tenant B"
assert_json_condition "$TENANTS_B_JSON" 'any(.[]; .id == "'"$TENANT_B"'")' "Usuario B no ve su tenant"
assert_json_condition "$TENANTS_B_JSON" 'all(.[]; .id != "'"$TENANT_A"'")' "Usuario B ve tenant A"

info "Validando aislamiento sobre endpoints por tenant"
assert_http_code 404 -H "Authorization: Bearer $USER_A_TOKEN" "$API/v1/tenants/$TENANT_B/events"
assert_http_code 404 -H "Authorization: Bearer $USER_A_TOKEN" "$API/v1/tenants/$TENANT_B/sensors"
assert_http_code 404 -H "Authorization: Bearer $USER_A_TOKEN" "$API/v1/tenants/$TENANT_B/audit"
assert_http_code 404 -H "Authorization: Bearer $USER_A_TOKEN" "$API/v1/tenants/$TENANT_B/webhook"
assert_http_code 404 -H "Authorization: Bearer $USER_A_TOKEN" "$API/v1/tenants/$TENANT_B/webhook-deliveries"

assert_http_code 404 -H "Authorization: Bearer $USER_B_TOKEN" "$API/v1/tenants/$TENANT_A/events"
assert_http_code 404 -H "Authorization: Bearer $USER_B_TOKEN" "$API/v1/tenants/$TENANT_A/sensors"
assert_http_code 404 -H "Authorization: Bearer $USER_B_TOKEN" "$API/v1/tenants/$TENANT_A/audit"
assert_http_code 404 -H "Authorization: Bearer $USER_B_TOKEN" "$API/v1/tenants/$TENANT_A/webhook"
assert_http_code 404 -H "Authorization: Bearer $USER_B_TOKEN" "$API/v1/tenants/$TENANT_A/webhook-deliveries"

info "Validando que cada usuario solo ve sus propios eventos"
EVENTS_A_JSON="$(curl -sS "$API/v1/tenants/$TENANT_A/events?limit=50" \
  -H "Authorization: Bearer $USER_A_TOKEN")"
EVENTS_B_JSON="$(curl -sS "$API/v1/tenants/$TENANT_B/events?limit=50" \
  -H "Authorization: Bearer $USER_B_TOKEN")"

assert_json_condition "$EVENTS_A_JSON" 'any(.items[]?; .id == "'"$EVENT_A_ID"'")' "Usuario A no ve su evento"
assert_json_condition "$EVENTS_A_JSON" 'all(.items[]?; .id != "'"$EVENT_B_ID"'")' "Usuario A ve evento de tenant B"

assert_json_condition "$EVENTS_B_JSON" 'any(.items[]?; .id == "'"$EVENT_B_ID"'")' "Usuario B no ve su evento"
assert_json_condition "$EVENTS_B_JSON" 'all(.items[]?; .id != "'"$EVENT_A_ID"'")' "Usuario B ve evento de tenant A"

ok "T31 tenant isolation: OK"