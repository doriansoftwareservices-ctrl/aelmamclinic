BEGIN;

-- Ensure core auth roles exist (idempotent).
DO $$
BEGIN
  IF to_regclass('auth.roles') IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO auth.roles(role)
  SELECT unnest(ARRAY[
    'user','superadmin','anonymous','owner','employee','admin','me'
  ])
  ON CONFLICT DO NOTHING;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'roles'
      AND column_name = 'is_default'
  ) THEN
    UPDATE auth.roles
    SET is_default = (role = 'user')
    WHERE role IN ('user','superadmin','anonymous','owner','employee','admin','me');
  END IF;
END;
$$;

-- Ensure providers used by auth exist.
DO $$
BEGIN
  IF to_regclass('auth.providers') IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO auth.providers(id)
  SELECT unnest(ARRAY['email-password','email','anonymous'])
  ON CONFLICT DO NOTHING;
END;
$$;

-- Ensure refresh token types exist (compat).
DO $$
DECLARE
  has_comment boolean;
BEGIN
  IF to_regclass('auth.refresh_token_types') IS NULL THEN
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'refresh_token_types'
      AND column_name = 'comment'
  ) INTO has_comment;

  IF has_comment THEN
    INSERT INTO auth.refresh_token_types(value, comment)
    VALUES
      ('refresh_token','default'),
      ('refresh-token','compat')
    ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO auth.refresh_token_types(value)
    VALUES
      ('refresh_token'),
      ('refresh-token')
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

-- Normalize auth.users roles to prevent auth 500s.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'default_role'
  ) THEN
    UPDATE auth.users
    SET default_role = 'user'
    WHERE default_role IS NULL
       OR lower(default_role) NOT IN ('user','superadmin','anonymous','owner','employee','admin','me');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'roles'
  ) THEN
    UPDATE auth.users u
    SET roles = CASE
      WHEN EXISTS (
        SELECT 1
        FROM public.super_admins sa
        WHERE sa.user_uid = u.id
           OR (sa.email IS NOT NULL AND lower(sa.email) = lower(u.email))
      ) THEN ARRAY['user','superadmin']::text[]
      ELSE ARRAY['user']::text[]
    END;
  END IF;
END;
$$;

-- Keep auth.user_roles consistent when table exists.
DO $$
BEGIN
  IF to_regclass('auth.user_roles') IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM auth.user_roles
  WHERE role IS NULL
     OR lower(role) NOT IN ('user','superadmin');

  DELETE FROM auth.user_roles ur
  WHERE lower(ur.role) = 'superadmin'
    AND NOT EXISTS (
      SELECT 1
      FROM public.super_admins sa
      JOIN auth.users u ON u.id = ur.user_id
      WHERE sa.user_uid = ur.user_id
         OR (sa.email IS NOT NULL AND lower(sa.email) = lower(u.email))
    );

  INSERT INTO auth.user_roles(user_id, role)
  SELECT u.id, 'user'
  FROM auth.users u
  WHERE NOT EXISTS (
    SELECT 1
    FROM auth.user_roles ur
    WHERE ur.user_id = u.id
      AND ur.role = 'user'
  );

  INSERT INTO auth.user_roles(user_id, role)
  SELECT u.id, 'superadmin'
  FROM auth.users u
  JOIN public.super_admins sa
    ON sa.user_uid = u.id
    OR (
      sa.user_uid IS NULL
      AND sa.email IS NOT NULL
      AND lower(sa.email) = lower(u.email)
    )
  WHERE NOT EXISTS (
    SELECT 1
    FROM auth.user_roles ur
    WHERE ur.user_id = u.id
      AND ur.role = 'superadmin'
  );
END;
$$;

COMMIT;
