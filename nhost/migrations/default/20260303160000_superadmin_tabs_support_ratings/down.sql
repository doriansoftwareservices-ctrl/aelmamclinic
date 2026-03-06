BEGIN;

ALTER TABLE public.super_admin_tab_permissions
  ALTER COLUMN allowed_tabs
  SET DEFAULT ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];

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

CREATE OR REPLACE FUNCTION public.admin_set_super_admin_tabs(
  p_user_uid uuid,
  p_allowed_tabs text[]
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_allowed text[];
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  IF public.fn_is_root_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_user_uid IS NULL THEN
    RETURN QUERY SELECT false, 'missing user', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT array_agg(x)
  INTO v_allowed
  FROM (
    SELECT DISTINCT lower(trim(t)) AS x
    FROM unnest(coalesce(p_allowed_tabs, '{}'::text[])) t
    WHERE lower(trim(t)) IN (
      'clinics','chats','subscriptions','payments','complaints','stats','members'
    )
  ) s;

  IF v_allowed IS NULL OR array_length(v_allowed, 1) IS NULL THEN
    v_allowed := v_default;
  END IF;

  INSERT INTO public.super_admin_tab_permissions(user_uid, allowed_tabs, updated_at)
  VALUES (p_user_uid, v_allowed, now())
  ON CONFLICT (user_uid) DO UPDATE
  SET allowed_tabs = excluded.allowed_tabs,
      updated_at = excluded.updated_at;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, p_user_uid, NULL::uuid,
    NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

COMMIT;
