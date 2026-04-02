-- 0003_audit_log.sql — RF-21 Auditoría de acciones administrativas

BEGIN;

CREATE TABLE IF NOT EXISTS audit_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  actor_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,

  action        text NOT NULL,            -- ej: "tenant.webhook.update"
  target_type   text NOT NULL,            -- ej: "tenant_settings", "membership", "sensor"
  target_id     uuid NULL,                -- id del objeto afectado (si aplica)

  ip            inet NULL,
  user_agent    text NULL,

  details       jsonb NOT NULL DEFAULT '{}'::jsonb,  -- before/after u otros campos
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_tenant_time
  ON audit_log (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_log_actor_time
  ON audit_log (actor_user_id, created_at DESC);

COMMIT;
