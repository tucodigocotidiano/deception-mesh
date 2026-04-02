BEGIN;

CREATE TABLE IF NOT EXISTS webhook_delivery_attempts (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id    uuid NOT NULL REFERENCES webhook_deliveries(id) ON DELETE CASCADE,
  tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  event_id       uuid NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  attempt_number int NOT NULL,
  success        boolean NOT NULL,
  http_status    int NULL,
  error_message  text NULL,
  started_at     timestamptz NOT NULL DEFAULT now(),
  finished_at    timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_webhook_delivery_attempts_unique
  ON webhook_delivery_attempts (delivery_id, attempt_number);

CREATE INDEX IF NOT EXISTS idx_webhook_delivery_attempts_delivery
  ON webhook_delivery_attempts (delivery_id, started_at ASC);

CREATE INDEX IF NOT EXISTS idx_webhook_delivery_attempts_tenant_time
  ON webhook_delivery_attempts (tenant_id, started_at DESC);

COMMIT;
