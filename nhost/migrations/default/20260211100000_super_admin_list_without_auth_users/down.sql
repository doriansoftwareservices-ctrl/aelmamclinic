BEGIN;

DROP FUNCTION IF EXISTS public.admin_is_root_email();

ALTER TABLE public.super_admins
  DROP COLUMN IF EXISTS disabled,
  DROP COLUMN IF EXISTS default_role,
  DROP COLUMN IF EXISTS updated_at;

-- Restore admin_get_super_admin_tabs using fn_is_super_admin and auth.users.
CREATE OR REPLACE FUNCTION public.admin_get_super_admin_tabs()
RETURNS SETOF public.v_super_admin_tabs
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid;
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  BEGIN
    v_uid := nullif(public.request_uid_text(), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
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

-- Restore admin_list_super_admin_accounts using auth.users.
CREATE OR REPLACE FUNCTION public.admin_list_super_admin_accounts()
RETURNS SETOF public.v_super_admin_account
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  IF public.fn_is_root_super_admin() IS DISTINCT FROM true THEN
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

-- Restore admin_set_super_admin_disabled using auth.users lookup.
CREATE OR REPLACE FUNCTION public.admin_set_super_admin_disabled(
  p_email text,
  p_disabled boolean
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text := lower(coalesce(trim(p_email), ''));
  v_uid uuid;
BEGIN
  IF public.fn_is_root_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_email = '' THEN
    RETURN QUERY SELECT false, 'missing email', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_email = 'elmam.clinic.c.s@elmam.com' THEN
    RETURN QUERY SELECT false, 'cannot disable root super admin',
      NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT u.id INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'user not found', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  UPDATE auth.users
  SET disabled = coalesce(p_disabled, false)
  WHERE id = v_uid;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, NULL::text,
    NULL::boolean, coalesce(p_disabled, false);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_super_admin_disabled(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_super_admin_disabled(text, boolean) TO PUBLIC;

-- Restore admin_delete_super_admin with auth.users lookup.
CREATE OR REPLACE FUNCTION public.admin_delete_super_admin(
  p_email text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_email text := lower(coalesce(trim(p_email), ''));
  v_uid uuid;
BEGIN
  IF public.fn_is_root_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_email = '' THEN
    RETURN QUERY SELECT false, 'missing email', NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_email = 'elmam.clinic.c.s@elmam.com' THEN
    RETURN QUERY SELECT false, 'cannot delete root super admin',
      NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT u.id INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  DELETE FROM public.super_admins
  WHERE lower(email) = v_email;

  IF v_uid IS NOT NULL THEN
    DELETE FROM public.super_admin_tab_permissions
    WHERE user_uid = v_uid;

    BEGIN
      DELETE FROM auth.user_roles
      WHERE user_id = v_uid AND role = 'superadmin';
    EXCEPTION WHEN undefined_column THEN
      BEGIN
        DELETE FROM auth.user_roles
        WHERE "userId" = v_uid AND role = 'superadmin';
      EXCEPTION WHEN others THEN
        NULL;
      END;
    END;

    UPDATE auth.users
    SET disabled = true
    WHERE id = v_uid;
  END IF;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, v_uid, NULL::uuid, NULL::text,
    NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_delete_super_admin(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_super_admin(text) TO PUBLIC;

COMMIT;
