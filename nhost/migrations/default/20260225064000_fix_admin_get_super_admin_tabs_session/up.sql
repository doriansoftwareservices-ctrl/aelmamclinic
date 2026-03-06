BEGIN;

-- Session-argument based resolver (most reliable in Hasura).
CREATE OR REPLACE FUNCTION public.admin_get_super_admin_tabs(hasura_session json)
RETURNS SETOF public.v_super_admin_tabs
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid_text text := coalesce(hasura_session ->> 'x-hasura-user-id', '');
  v_role text := lower(coalesce(hasura_session ->> 'x-hasura-role', ''));
  v_email text := lower(coalesce(hasura_session ->> 'x-hasura-user-email', ''));
  v_uid uuid;
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
  v_has_admin boolean := false;
BEGIN
  IF v_role <> 'superadmin' THEN
    RETURN;
  END IF;

  IF v_uid_text <> '' THEN
    BEGIN
      v_uid := v_uid_text::uuid;
    EXCEPTION WHEN others THEN
      v_uid := NULL;
    END;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT true INTO v_has_admin
    FROM public.super_admins sa
    WHERE sa.user_uid = v_uid
    LIMIT 1;
  END IF;

  IF v_has_admin IS DISTINCT FROM true AND v_email <> '' THEN
    SELECT true INTO v_has_admin
    FROM public.super_admins sa
    WHERE lower(sa.email) = v_email
    LIMIT 1;
  END IF;

  IF v_has_admin IS DISTINCT FROM true THEN
    RETURN;
  END IF;

  IF v_uid IS NULL AND v_email <> '' THEN
    SELECT u.id INTO v_uid
    FROM auth.users u
    WHERE lower(u.email) = v_email
    LIMIT 1;
  END IF;

  IF v_uid IS NULL THEN
    RETURN QUERY SELECT v_default;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT coalesce(p.allowed_tabs, v_default)
  FROM public.super_admin_tab_permissions p
  WHERE p.user_uid = v_uid;

  IF NOT FOUND THEN
    RETURN QUERY SELECT v_default;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_super_admin_tabs(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_get_super_admin_tabs(json) TO PUBLIC;

COMMIT;
