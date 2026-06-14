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
  ) INTO can_manage_auth_users;

  IF can_manage_auth_users THEN
    EXECUTE 'DROP TRIGGER IF EXISTS trg_normalize_auth_users_json ON auth.users';
  ELSE
    RAISE NOTICE 'Skipping drop of auth.users JSON normalization trigger: current role % is not owner of auth.users', current_user;
  END IF;
END;
$$;
DROP FUNCTION IF EXISTS public.trg_normalize_auth_users_json();
DROP FUNCTION IF EXISTS public.normalize_auth_jsonb(jsonb);

COMMIT;
