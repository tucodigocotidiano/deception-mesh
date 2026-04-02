BEGIN;

INSERT INTO users (id, email, password_hash)
VALUES (
  '11111111-1111-1111-1111-111111111111',
  'admin@acme.com',
  '$argon2id$v=19$m=65536,t=3,p=4$G8kwoHO+KUG5dB+H1eHzow$HHcVL+54KcBTvzEFDUMMVgYHRJrJ4IhTLf7Q1oqs4dw'
)
ON CONFLICT (email) DO NOTHING;

COMMIT;
