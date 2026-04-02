#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_lib.sh"

require_base_deps
ensure_stack
wait_for_http_200 "$API/health" "/health"
wait_for_http_200 "$API/ready" "/ready"

info "Validando acceso a endpoint protegido sin token"
assert_http_code 401 "$API/v1/tenants"

info "Validando token inválido"
assert_http_code 401 \
  -H "Authorization: Bearer not-a-real-token" \
  "$API/v1/tenants"

info "Validando login inválido"
assert_http_code 401 \
  -X POST "$API/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@acme.com","password":"wrong-password"}'

info "Autenticando admin seed"
ADMIN_LOGIN_JSON="$(login_json "$ADMIN_EMAIL" "$ADMIN_PASSWORD")"
ADMIN_TOKEN="$(json_field "$ADMIN_LOGIN_JSON" '.access_token')"
ADMIN_USER_ID="$(json_field "$ADMIN_LOGIN_JSON" '.user_id')"

[ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ] || die "No se obtuvo access_token admin"
[ -n "$ADMIN_USER_ID" ] && [ "$ADMIN_USER_ID" != "null" ] || die "No se obtuvo user_id admin"

READONLY_EMAIL="readonly.t31.$(date +%s)@acme.com"
READONLY_USER_ID="$(ensure_user "$READONLY_EMAIL")"

info "Autenticando usuario readonly"
READONLY_LOGIN_JSON="$(login_json "$READONLY_EMAIL" "$TEST_DEFAULT_PASSWORD")"
READONLY_TOKEN="$(json_field "$READONLY_LOGIN_JSON" '.access_token')"

[ -n "$READONLY_TOKEN" ] && [ "$READONLY_TOKEN" != "null" ] || die "No se obtuvo token readonly"

TENANT_ID="$(create_tenant "Tenant T31 Auth RBAC $(date +%s)")"
grant_membership "$TENANT_ID" "$ADMIN_USER_ID" "admin"
grant_membership "$TENANT_ID" "$READONLY_USER_ID" "readonly"

info "Validando que admin puede modificar webhook"
assert_http_code 200 \
  -X PUT "$API/v1/tenants/$TENANT_ID/webhook" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"webhook_url":"http://example.invalid/hook","webhook_min_severity":2}'

info "Validando que readonly puede leer webhook"
assert_http_code 200 \
  -H "Authorization: Bearer $READONLY_TOKEN" \
  "$API/v1/tenants/$TENANT_ID/webhook"

info "Validando que readonly NO puede modificar webhook"
assert_http_code 403 \
  -X PUT "$API/v1/tenants/$TENANT_ID/webhook" \
  -H "Authorization: Bearer $READONLY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"webhook_url":"http://forbidden.invalid/hook","webhook_min_severity":1}'

info "Validando que readonly NO puede crear enroll token"
assert_http_code 403 \
  -X POST "$API/v1/tenants/$TENANT_ID/sensors/enroll-token" \
  -H "Authorization: Bearer $READONLY_TOKEN"

info "Creando enroll token como admin para verificar auditoría"
ENROLL_JSON="$(curl -sS -X POST "$API/v1/tenants/$TENANT_ID/sensors/enroll-token" \
  -H "Authorization: Bearer $ADMIN_TOKEN")"

assert_json_condition "$ENROLL_JSON" '.enroll_token != null' "No se creó enroll token"

info "Verificando auditoría del tenant"
AUDIT_JSON="$(curl -sS "$API/v1/tenants/$TENANT_ID/audit?limit=50" \
  -H "Authorization: Bearer $ADMIN_TOKEN")"

assert_json_condition \
  "$AUDIT_JSON" \
  'any(.[]; .action == "tenant.webhook.update")' \
  "No encontré audit log de tenant.webhook.update"

assert_json_condition \
  "$AUDIT_JSON" \
  'any(.[]; .action == "sensor.enroll_token.create")' \
  "No encontré audit log de sensor.enroll_token.create"

ok "T31 auth + RBAC + auditoría: OK"