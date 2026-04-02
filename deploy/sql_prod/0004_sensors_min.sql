-- 0004_sensors_min.sql — sensors (T08 schema)
BEGIN;

CREATE TABLE IF NOT EXISTS sensors (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name         text NOT NULL,
  token_hash   text NULL,                -- T08: hash de token del sensor
  status       text NOT NULL DEFAULT 'pending',
  created_at   timestamptz NOT NULL DEFAULT now(),
  registered_at timestamptz NULL
);

-- Si venías de una tabla mínima, agrega columnas sin romper
ALTER TABLE sensors
  ADD COLUMN IF NOT EXISTS token_hash text NULL;

ALTER TABLE sensors
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending';

ALTER TABLE sensors
  ADD COLUMN IF NOT EXISTS registered_at timestamptz NULL;

CREATE INDEX IF NOT EXISTS idx_sensors_tenant_id ON sensors(tenant_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sensors_token_hash_unique
  ON sensors(tenant_id, token_hash);

COMMIT;
