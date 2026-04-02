-- 0005_sensor_enroll_tokens.sql — enroll tokens para registrar sensores (T08)
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS sensor_enroll_tokens (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  token_hash text NOT NULL,
  created_by uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at    timestamptz NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_enroll_tokens_unique
  ON sensor_enroll_tokens (tenant_id, token_hash);

CREATE INDEX IF NOT EXISTS idx_enroll_tokens_valid
  ON sensor_enroll_tokens (tenant_id, expires_at)
  WHERE used_at IS NULL;

COMMIT;
