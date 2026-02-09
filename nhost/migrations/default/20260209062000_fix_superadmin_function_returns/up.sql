BEGIN;

CREATE OR REPLACE VIEW public.v_super_admin_tabs AS
SELECT NULL::text[] AS allowed_tabs
WHERE false;

CREATE OR REPLACE VIEW public.v_super_admin_account AS
SELECT
  NULL::text AS email,
  NULL::uuid AS user_uid,
  NULL::timestamptz AS created_at,
  NULL::boolean AS disabled,
  NULL::text AS default_role,
  NULL::text[] AS allowed_tabs,
  NULL::boolean AS has_user
WHERE false;

CREATE OR REPLACE FUNCTION public.admin_get_super_admin_tabs()
RETURNS SETOF public.v_super_admin_tabs
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid;
  v_email text;
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  BEGIN
    v_uid := nullif((current_setting('request.jwt.claims', true)::json->>'sub'), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT lower(u.email) INTO v_email
  FROM auth.users u
  WHERE u.id = v_uid;

  IF NOT EXISTS (
    SELECT 1
    FROM public.super_admins sa
    WHERE sa.user_uid = v_uid OR lower(sa.email) = v_email
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
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

REVOKE ALL ON FUNCTION public.admin_get_super_admin_tabs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_get_super_admin_tabs() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_get_super_admin_tabs() TO public;

CREATE OR REPLACE FUNCTION public.admin_list_super_admin_accounts()
RETURNS SETOF public.v_super_admin_account
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid;
  v_me_email text;
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  BEGIN
    v_uid := nullif((current_setting('request.jwt.claims', true)::json->>'sub'), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT lower(u.email) INTO v_me_email
  FROM auth.users u
  WHERE u.id = v_uid;

  IF v_me_email IS DISTINCT FROM lower('elmam.clinic.c.s@elmam.com') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    sa.email,
    coalesce(sa.user_uid, u.id) AS user_uid,
    sa.created_at,
    coalesce(u.disabled, false) AS disabled,
    coalesce(u.default_role, 'user') AS default_role,
    coalesce(p.allowed_tabs, v_default) AS allowed_tabs,
    (u.id IS NOT NULL) AS has_user
  FROM public.super_admins sa
  LEFT JOIN auth.users u
    ON u.id = sa.user_uid OR lower(u.email) = lower(sa.email)
  LEFT JOIN public.super_admin_tab_permissions p
    ON p.user_uid = u.id
  ORDER BY sa.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO public;

COMMIT;
