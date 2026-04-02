BEGIN;

ALTER TABLE events
  ADD COLUMN IF NOT EXISTS severity text NOT NULL DEFAULT 'low';

ALTER TABLE events
  ADD COLUMN IF NOT EXISTS severity_reason text NOT NULL DEFAULT 'default_low';

ALTER TABLE events
  ADD COLUMN IF NOT EXISTS attempt_count int NOT NULL DEFAULT 1;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'events_severity_check'
  ) THEN
    ALTER TABLE events
      ADD CONSTRAINT events_severity_check
      CHECK (severity IN ('low', 'medium', 'high', 'critical'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_events_tenant_severity_time
  ON events (tenant_id, severity, occurred_at DESC);

COMMIT;