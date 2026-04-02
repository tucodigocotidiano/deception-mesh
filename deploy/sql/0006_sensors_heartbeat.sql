-- 0006_sensors_heartbeat.sql — T09 Heartbeat + metadata de sensor
BEGIN;

ALTER TABLE sensors
  ADD COLUMN IF NOT EXISTS last_seen timestamptz NULL;

ALTER TABLE sensors
  ADD COLUMN IF NOT EXISTS agent_version text NULL;

ALTER TABLE sensors
  ADD COLUMN IF NOT EXISTS rtt_ms int NULL;

-- Índices útiles
CREATE INDEX IF NOT EXISTS idx_sensors_tenant_last_seen
  ON sensors (tenant_id, last_seen DESC);

COMMIT;
