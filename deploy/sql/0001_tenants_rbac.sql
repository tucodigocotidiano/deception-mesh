-- 0001_tenants_rbac.sql
-- Deception Mesh — T05 Multi-tenant + RBAC (Admin/Analyst/ReadOnly)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'role_kind') THEN
    CREATE TYPE role_kind AS ENUM ('admin', 'analyst', 'readonly');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS tenants (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email        citext NOT NULL UNIQUE,
  password_hash text NULL, -- se usará en T06 (auth real)
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS memberships (
  tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role        role_kind NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_memberships_user_id ON memberships(user_id);
CREATE INDEX IF NOT EXISTS idx_memberships_tenant_id ON memberships(tenant_id);

-- Una tabla simple para probar RBAC (ReadOnly NO puede cambiar webhook)
CREATE TABLE IF NOT EXISTS tenant_settings (
  tenant_id           uuid PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
  webhook_url         text NULL,
  webhook_min_severity int NOT NULL DEFAULT 2,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMIT;
