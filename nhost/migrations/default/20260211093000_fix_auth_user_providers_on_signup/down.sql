BEGIN;

DO $$
DECLARE
  can_manage_auth_users boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_roles r ON r.oid = c.relowner
    WHERE n.nspname = 'auth'
      AND c.relname = 'users'
      AND r.rolname = current_user
  )
  AND has_schema_privilege('auth', 'USAGE')
  AND has_schema_privilege('auth', 'CREATE')
  INTO can_manage_auth_users;

  IF NOT can_manage_auth_users THEN
    RAISE NOTICE 'Skipping down migration for auth.ensure_user_provider_email_password: current role % is not owner/creator for auth.users/auth schema', current_user;
    RETURN;
  END IF;

  EXECUTE 'DROP TRIGGER IF EXISTS trg_ensure_user_provider_email_password ON auth.users';
  EXECUTE 'DROP FUNCTION IF EXISTS auth.ensure_user_provider_email_password()';
END;
$$;

COMMIT;
