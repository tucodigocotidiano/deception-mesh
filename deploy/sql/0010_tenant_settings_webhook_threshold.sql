BEGIN;

UPDATE tenant_settings
SET webhook_min_severity = LEAST(4, GREATEST(1, COALESCE(webhook_min_severity, 2)));

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'tenant_settings_webhook_min_severity_check'
  ) THEN
    ALTER TABLE tenant_settings
      ADD CONSTRAINT tenant_settings_webhook_min_severity_check
      CHECK (webhook_min_severity BETWEEN 1 AND 4);
  END IF;
END $$;

COMMIT;