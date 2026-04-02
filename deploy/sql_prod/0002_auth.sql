-- 0002_auth.sql — Auth (password_hash) + helpers mínimos

BEGIN;

-- Por si la columna no existiera (ya la tienes en 0001, pero esto lo hace idempotente)
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS password_hash text NULL;

COMMIT;
