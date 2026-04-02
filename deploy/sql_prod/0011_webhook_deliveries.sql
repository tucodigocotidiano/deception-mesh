BEGIN;

CREATE TABLE IF NOT EXISTS webhook_deliveries (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  event_id         uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  sensor_id        uuid NOT NULL REFERENCES sensors(id) ON DELETE CASCADE,
  target_url       text NOT NULL,
  payload          jsonb NOT NULL,
  status           text NOT NULL DEFAULT 'pending',
  attempt_count    int NOT NULL DEFAULT 0,
  max_attempts     int NOT NULL DEFAULT 4,
  next_attempt_at  timestamptz NULL DEFAULT now(),
  last_attempt_at  timestamptz NULL,
  delivered_at     timestamptz NULL,
  last_status_code int NULL,
  last_error       text NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'webhook_deliveries_status_check'
  ) THEN
    ALTER TABLE webhook_deliveries
      ADD CONSTRAINT webhook_deliveries_status_check
      CHECK (status IN ('pending', 'in_progress', 'retrying', 'delivered', 'failed'));
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'webhook_deliveries_max_attempts_check'
  ) THEN
    ALTER TABLE webhook_deliveries
      ADD CONSTRAINT webhook_deliveries_max_attempts_check
      CHECK (max_attempts >= 4);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_webhook_deliveries_event_target_unique
  ON webhook_deliveries (event_id, target_url);

CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_due
  ON webhook_deliveries (status, next_attempt_at, created_at);

CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_tenant_time
  ON webhook_deliveries (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_event
  ON webhook_deliveries (event_id);

COMMIT;
