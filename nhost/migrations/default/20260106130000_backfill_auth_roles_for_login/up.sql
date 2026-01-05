BEGIN;

-- Link super_admins to auth.users by email.
UPDATE public.super_admins sa
SET user_uid = u.id
FROM auth.users u
WHERE sa.user_uid IS NULL
  AND sa.email IS NOT NULL
  AND lower(sa.email) = lower(u.email);

-- Normalize auth.users roles to allowed set.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'default_role'
  ) THEN
    EXECUTE $sql$
      UPDATE auth.users
      SET default_role = 'user'
      WHERE default_role IS NULL
         OR lower(default_role) NOT IN ('user', 'superadmin', 'anonymous')
    $sql$;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'roles'
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
