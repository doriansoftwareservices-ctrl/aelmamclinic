BEGIN;

-- Normalize any auth.users JSON field to a JSON object (never array or scalar).
CREATE OR REPLACE FUNCTION public.normalize_auth_jsonb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v jsonb;
BEGIN
  IF p IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  IF jsonb_typeof(p) = 'object' THEN
    RETURN p;
  ELSIF jsonb_typeof(p) = 'array' THEN
    v := COALESCE(p->0, p->1, '{}'::jsonb);
    IF v IS NULL OR jsonb_typeof(v) <> 'object' THEN
      RETURN '{}'::jsonb;
    END IF;
    RETURN v;
  END IF;

  RETURN '{}'::jsonb;
END;
$$;

-- Ensure auth.users JSON columns are normalized on insert/update.
CREATE OR REPLACE FUNCTION public.trg_normalize_auth_users_json()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_row jsonb := '{}'::jsonb;
BEGIN
  v_row := to_jsonb(NEW);
  v_row := jsonb_set(v_row, '{metadata}', public.normalize_auth_jsonb(v_row->'metadata'), true);
  v_row := jsonb_set(v_row, '{app_metadata}', public.normalize_auth_jsonb(v_row->'app_metadata'), true);
  v_row := jsonb_set(v_row, '{raw_app_meta_data}', public.normalize_auth_jsonb(v_row->'raw_app_meta_data'), true);
  v_row := jsonb_set(v_row, '{raw_user_meta_data}', public.normalize_auth_jsonb(v_row->'raw_user_meta_data'), true);
  RETURN jsonb_populate_record(NEW, v_row);
END;
$$;

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
    EXECUTE $sql$
      CREATE TRIGGER trg_normalize_auth_users_json
      BEFORE INSERT OR UPDATE ON auth.users
      FOR EACH ROW
      EXECUTE FUNCTION public.trg_normalize_auth_users_json()
    $sql$;
  ELSE
    RAISE NOTICE 'Skipping auth.users JSON normalization trigger: current role % is not owner of auth.users', current_user;
  END IF;
END;
$$;

-- Normalize existing rows (one-time cleanup) only when the migration role can update auth.users.
DO $$
DECLARE
  col text;
  can_update_auth_users boolean := false;
BEGIN
  SELECT COALESCE(has_table_privilege('auth.users', 'UPDATE'), false)
  INTO can_update_auth_users;

  IF NOT can_update_auth_users THEN
    RAISE NOTICE 'Skipping auth.users existing-row JSON cleanup: current role % cannot update auth.users', current_user;
    RETURN;
  END IF;

  FOR col IN SELECT unnest(ARRAY['metadata','app_metadata','raw_app_meta_data','raw_user_meta_data'])
  LOOP
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'auth'
        AND table_name = 'users'
        AND column_name = col
    ) THEN
      EXECUTE format(
        'UPDATE auth.users SET %I = public.normalize_auth_jsonb(%I)',
        col, col
      );
    END IF;
  END LOOP;
END $$;

-- Hardening: ensure auth_set_user_claims always works with normalized JSON.
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
      AND (role IS NULL OR lower(role) NOT IN ('user','superadmin','anonymous'));

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
    EXECUTE 'UPDATE auth.users SET metadata = public.normalize_auth_jsonb(metadata) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'app_metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET app_metadata = public.normalize_auth_jsonb(app_metadata) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'raw_app_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_app_meta_data = public.normalize_auth_jsonb(raw_app_meta_data) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'raw_user_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_user_meta_data = public.normalize_auth_jsonb(raw_user_meta_data) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO PUBLIC;

COMMIT;
