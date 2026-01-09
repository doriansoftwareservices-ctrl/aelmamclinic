BEGIN;

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
  v_domain_role text := lower(coalesce(nullif(p_role, ''), 'employee'));
  v_account text := nullif(p_account::text, '');
  v_meta jsonb := jsonb_strip_nulls(
    jsonb_build_object('role', v_domain_role, 'account_id', v_account)
  );
  v_default_role text := 'user';
  v_roles text[] := ARRAY['user'];
BEGIN
  IF p_uid IS NULL THEN
    RAISE EXCEPTION 'uid is required';
  END IF;

  IF v_domain_role = 'superadmin' THEN
    v_roles := ARRAY['user','superadmin'];
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

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET metadata = COALESCE((CASE WHEN jsonb_typeof(metadata) = ''array'' THEN metadata->1 ELSE metadata END), ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'app_metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET app_metadata = COALESCE((CASE WHEN jsonb_typeof(app_metadata) = ''array'' THEN app_metadata->1 ELSE app_metadata END), ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'raw_app_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_app_meta_data = COALESCE((CASE WHEN jsonb_typeof(raw_app_meta_data) = ''array'' THEN raw_app_meta_data->1 ELSE raw_app_meta_data END), ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'raw_user_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_user_meta_data = COALESCE((CASE WHEN jsonb_typeof(raw_user_meta_data) = ''array'' THEN raw_user_meta_data->1 ELSE raw_user_meta_data END), ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF to_regclass('auth.user_roles') IS NOT NULL THEN
    DELETE FROM auth.user_roles
    WHERE user_id = p_uid
      AND role <> ALL(v_roles);

    INSERT INTO auth.user_roles(user_id, role)
    SELECT p_uid, unnest(v_roles)
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO PUBLIC;

DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET metadata = COALESCE((CASE WHEN jsonb_typeof(metadata) = ''array'' THEN metadata->1 ELSE metadata END), ''{}''::jsonb) WHERE metadata IS NOT NULL';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'app_metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET app_metadata = COALESCE((CASE WHEN jsonb_typeof(app_metadata) = ''array'' THEN app_metadata->1 ELSE app_metadata END), ''{}''::jsonb) WHERE app_metadata IS NOT NULL';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'raw_app_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_app_meta_data = COALESCE((CASE WHEN jsonb_typeof(raw_app_meta_data) = ''array'' THEN raw_app_meta_data->1 ELSE raw_app_meta_data END), ''{}''::jsonb) WHERE raw_app_meta_data IS NOT NULL';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'raw_user_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_user_meta_data = COALESCE((CASE WHEN jsonb_typeof(raw_user_meta_data) = ''array'' THEN raw_user_meta_data->1 ELSE raw_user_meta_data END), ''{}''::jsonb) WHERE raw_user_meta_data IS NOT NULL';
  END IF;
END;
$$;

COMMIT;
