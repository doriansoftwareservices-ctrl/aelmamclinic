BEGIN;

-- Ensure only "user" is default when auth.roles supports is_default.
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
    WHERE role IN ('user', 'superadmin', 'anonymous', 'owner', 'employee', 'admin', 'me');
  END IF;
END;
$$;

-- Normalize auth.user_roles to allowed roles only.
DO $$
BEGIN
  IF to_regclass('auth.user_roles') IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM auth.user_roles
  WHERE role IS NULL
     OR lower(role) NOT IN ('user', 'superadmin');

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

-- Normalize auth.users role columns if they exist.
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
       OR lower(default_role) NOT IN ('user', 'superadmin');
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

-- Keep auth claims aligned with allowed Hasura roles and auth.user_roles.
CREATE OR REPLACE FUNCTION public.auth_set_user_claims(
  p_uid uuid,
  p_role text,
  p_account uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_domain_role text := lower(coalesce(nullif(trim(p_role), ''), 'employee'));
  v_account text := nullif(p_account::text, '');
  v_meta jsonb := jsonb_strip_nulls(
    jsonb_build_object('role', v_domain_role, 'account_id', v_account)
  );

  v_email text;
  v_is_super boolean := false;
  v_roles text[] := ARRAY['user']::text[];
  v_default_role text := 'user';
BEGIN
  IF p_uid IS NULL THEN
    RAISE EXCEPTION 'uid is required';
  END IF;

  SELECT lower(u.email)
  INTO v_email
  FROM auth.users u
  WHERE u.id = p_uid
  LIMIT 1;

  v_is_super := (v_domain_role = 'superadmin') OR EXISTS (
    SELECT 1
    FROM public.super_admins sa
    WHERE sa.user_uid = p_uid
       OR (v_email IS NOT NULL AND lower(sa.email) = v_email)
  );

  IF v_is_super THEN
    v_roles := ARRAY['user','superadmin']::text[];
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'default_role'
  ) THEN
    EXECUTE 'UPDATE auth.users SET default_role = $2 WHERE id = $1'
      USING p_uid, v_default_role;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'roles'
  ) THEN
    EXECUTE 'UPDATE auth.users SET roles = $2 WHERE id = $1'
      USING p_uid, v_roles;
  END IF;

  IF to_regclass('auth.user_roles') IS NOT NULL THEN
    DELETE FROM auth.user_roles
    WHERE user_id = p_uid
      AND (
        role IS NULL
        OR lower(role) NOT IN ('user','superadmin')
        OR (lower(role) = 'superadmin' AND NOT v_is_super)
      );

    INSERT INTO auth.user_roles(user_id, role)
    SELECT p_uid, v_default_role
    WHERE NOT EXISTS (
      SELECT 1
      FROM auth.user_roles ur
      WHERE ur.user_id = p_uid
        AND ur.role = v_default_role
    );

    IF v_is_super THEN
      INSERT INTO auth.user_roles(user_id, role)
      SELECT p_uid, 'superadmin'
      WHERE NOT EXISTS (
        SELECT 1
        FROM auth.user_roles ur
        WHERE ur.user_id = p_uid
          AND ur.role = 'superadmin'
      );
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET metadata = COALESCE(metadata, ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'app_metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET app_metadata = COALESCE(app_metadata, ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'raw_app_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_app_meta_data = COALESCE(raw_app_meta_data, ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'raw_user_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_user_meta_data = COALESCE(raw_user_meta_data, ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO PUBLIC;

COMMIT;