BEGIN;

-- Ensure only "user" is the default auth role for new users.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'roles'
      AND column_name = 'is_default'
  ) THEN
    UPDATE auth.roles
    SET is_default = (role = 'user')
    WHERE role IN ('user', 'anonymous', 'superadmin', 'owner', 'employee', 'admin');
  END IF;
END;
$$;

-- Strip "anonymous" from existing user role assignments to prevent login failures.
DO $$
BEGIN
  IF to_regclass('auth.user_roles') IS NOT NULL THEN
    DELETE FROM auth.user_roles
    WHERE lower(role) = 'anonymous';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'roles'
  ) THEN
    UPDATE auth.users
    SET roles = array_remove(roles, 'anonymous')
    WHERE roles @> ARRAY['anonymous']::text[];
  END IF;
END;
$$;

COMMIT;

