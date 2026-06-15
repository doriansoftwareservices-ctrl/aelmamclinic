BEGIN;

CREATE TABLE IF NOT EXISTS public.superadmin_whitelist (
  email text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.super_admin_tab_permissions (
  user_uid uuid PRIMARY KEY,
  allowed_tabs text[] NOT NULL DEFAULT ARRAY[]::text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Guardrail: a clinic account user (owner/admin/employee) must never be
-- routed as a platform super admin because of stale/incorrect Nhost JWT claims.
-- The authoritative source for superadmin is public.super_admins with disabled=false.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql(hasura_session json)
RETURNS SETOF public.v_is_super_admin
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, auth
AS $$
  WITH uid AS (
    SELECT nullif(hasura_session->>'x-hasura-user-id','')::uuid AS id
  ),
  em AS (
    SELECT lower(u.email) AS email
    FROM auth.users u
    JOIN uid ON uid.id = u.id
    LIMIT 1
  )
  SELECT (
    EXISTS (
      SELECT 1
      FROM public.super_admins s, uid, em
      WHERE coalesce(s.disabled, false) = false
        AND (
          (s.user_uid IS NOT NULL AND s.user_uid = uid.id)
          OR (s.email IS NOT NULL AND lower(s.email) = em.email)
        )
        AND (
          EXISTS (
            SELECT 1 FROM public.superadmin_whitelist sw
            WHERE lower(sw.email) = lower(coalesce(s.email, em.email, ''))
          )
          OR EXISTS (
            SELECT 1 FROM public.super_admin_tab_permissions tp
            WHERE tp.user_uid = coalesce(s.user_uid, uid.id)
          )
        )
    )
  ) AS is_super_admin;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql(json) TO PUBLIC;

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

  -- Do not trust p_role='superadmin' alone. The user must exist in the
  -- super_admins registry and must not be disabled there.
  v_is_super := EXISTS (
    SELECT 1
    FROM public.super_admins sa
    WHERE coalesce(sa.disabled, false) = false
      AND (
        sa.user_uid = p_uid
        OR (v_email IS NOT NULL AND sa.email IS NOT NULL AND lower(sa.email) = v_email)
      )
      AND (
        EXISTS (
          SELECT 1 FROM public.superadmin_whitelist sw
          WHERE lower(sw.email) = lower(coalesce(sa.email, v_email, ''))
        )
        OR EXISTS (
          SELECT 1 FROM public.super_admin_tab_permissions tp
          WHERE tp.user_uid = coalesce(sa.user_uid, p_uid)
        )
      )
  );

  IF v_is_super THEN
    v_domain_role := 'superadmin';
    v_account := NULL;
    v_meta := jsonb_build_object('role', 'superadmin');
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
    SELECT p_uid, 'user'
    WHERE NOT EXISTS (
      SELECT 1 FROM auth.user_roles ur
      WHERE ur.user_id = p_uid AND ur.role = 'user'
    );

    IF v_is_super THEN
      INSERT INTO auth.user_roles(user_id, role)
      SELECT p_uid, 'superadmin'
      WHERE NOT EXISTS (
        SELECT 1 FROM auth.user_roles ur
        WHERE ur.user_id = p_uid AND ur.role = 'superadmin'
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

-- Repair existing normal clinic users that accidentally received superadmin
-- JWT roles. Does not delete public.super_admins rows; it only normalizes users
-- that are not active superadmins according to public.super_admins.
DO $$
DECLARE
  r record;
  v_roles text[];
  v_domain_role text;
  v_account uuid;
  v_meta jsonb;
BEGIN
  FOR r IN
    SELECT
      u.id AS uid,
      lower(u.email) AS email,
      au.account_id,
      lower(coalesce(au.role, 'employee')) AS role,
      EXISTS (
        SELECT 1
        FROM public.super_admins sa
        WHERE coalesce(sa.disabled, false) = false
          AND (
            sa.user_uid = u.id
            OR (sa.email IS NOT NULL AND lower(sa.email) = lower(u.email))
          )
          AND (
            EXISTS (
              SELECT 1 FROM public.superadmin_whitelist sw
              WHERE lower(sw.email) = lower(coalesce(sa.email, u.email, ''))
            )
            OR EXISTS (
              SELECT 1 FROM public.super_admin_tab_permissions tp
              WHERE tp.user_uid = coalesce(sa.user_uid, u.id)
            )
          )
      ) AS is_active_super
    FROM auth.users u
    JOIN LATERAL (
      SELECT au2.account_id, au2.role
      FROM public.account_users au2
      WHERE au2.user_uid = u.id
        AND coalesce(au2.disabled, false) = false
      ORDER BY au2.created_at DESC
      LIMIT 1
    ) au ON true
  LOOP
    IF r.is_active_super THEN
      v_roles := ARRAY['user','superadmin']::text[];
      v_domain_role := 'superadmin';
      v_account := NULL;
    ELSE
      v_roles := ARRAY['user']::text[];
      v_domain_role := CASE
        WHEN r.role IN ('owner','admin','employee') THEN r.role
        ELSE 'employee'
      END;
      v_account := r.account_id;
    END IF;

    v_meta := jsonb_strip_nulls(
      jsonb_build_object('role', v_domain_role, 'account_id', v_account::text)
    );

    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='auth' AND table_name='users' AND column_name='default_role'
    ) THEN
      EXECUTE 'UPDATE auth.users SET default_role = ''user'' WHERE id = $1'
        USING r.uid;
    END IF;

    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='auth' AND table_name='users' AND column_name='roles'
    ) THEN
      EXECUTE 'UPDATE auth.users SET roles = $2 WHERE id = $1'
        USING r.uid, v_roles;
    END IF;

    IF to_regclass('auth.user_roles') IS NOT NULL THEN
      DELETE FROM auth.user_roles
      WHERE user_id = r.uid
        AND (
          role IS NULL
          OR lower(role) NOT IN ('user','superadmin')
          OR (lower(role) = 'superadmin' AND NOT r.is_active_super)
        );

      INSERT INTO auth.user_roles(user_id, role)
      SELECT r.uid, 'user'
      WHERE NOT EXISTS (
        SELECT 1 FROM auth.user_roles ur
        WHERE ur.user_id = r.uid AND ur.role = 'user'
      );

      IF r.is_active_super THEN
        INSERT INTO auth.user_roles(user_id, role)
        SELECT r.uid, 'superadmin'
        WHERE NOT EXISTS (
          SELECT 1 FROM auth.user_roles ur
          WHERE ur.user_id = r.uid AND ur.role = 'superadmin'
        );
      END IF;
    END IF;

    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema='auth' AND table_name='users' AND column_name='metadata'
    ) THEN
      EXECUTE 'UPDATE auth.users SET metadata = COALESCE(metadata, ''{}''::jsonb) || $2 WHERE id = $1'
        USING r.uid, v_meta;
    END IF;
  END LOOP;
END $$;

COMMIT;
