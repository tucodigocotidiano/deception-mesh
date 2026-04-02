BEGIN;

CREATE TABLE IF NOT EXISTS events (
  id             uuid PRIMARY KEY,
  tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  sensor_id      uuid NOT NULL REFERENCES sensors(id) ON DELETE CASCADE,
  schema_version int NOT NULL,
  service        text NOT NULL,
  src_ip         text NOT NULL,
  src_port       int NOT NULL,
  occurred_at    timestamptz NOT NULL,
  raw_event      jsonb NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_tenant_time
  ON events (tenant_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_sensor_time
  ON events (sensor_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_tenant_service_time
  ON events (tenant_id, service, occurred_at DESC);

COMMIT;