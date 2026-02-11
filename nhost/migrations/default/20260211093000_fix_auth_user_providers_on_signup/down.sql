BEGIN;

DROP TRIGGER IF EXISTS trg_ensure_user_provider_email_password ON auth.users;
DROP FUNCTION IF EXISTS auth.ensure_user_provider_email_password();

COMMIT;
