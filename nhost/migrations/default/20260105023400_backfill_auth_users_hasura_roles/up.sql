BEGIN;

-- ROLE-1 follow-up: normalize existing users so JWT claims match new role model.
-- - default_role => user
-- - roles => ['user'] OR ['user','superadmin'] for super admins

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='auth' AND table_name='users' AND column_name='default_role'
  ) THEN
    EXECUTE 'UPDATE auth.users SET default_role = ''user''';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='auth' AND table_name='users' AND column_name='roles'
  ) THEN
    EXECUTE $sql$
      UPDATE auth.users u
      SET roles = CASE
        WHEN EXISTS (
          SELECT 1 FROM public.super_admins sa
          WHERE sa.user_uid = u.id OR lower(sa.email) = lower(u.email)
        ) THEN ARRAY['user','superadmin']::text[]
        ELSE ARRAY['user']::text[]
      END
    $sql$;
  END IF;
END$$;

COMMIT;
