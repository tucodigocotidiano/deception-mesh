BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_events_tenant_sensor_time
  ON events (tenant_id, sensor_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_tenant_service_severity_time
  ON events (tenant_id, service, severity, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_tenant_src_ip_time
  ON events (tenant_id, src_ip, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_severity_reason_trgm
  ON events USING gin (severity_reason gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_events_raw_event_text_trgm
  ON events USING gin ((raw_event::text) gin_trgm_ops);

COMMIT;