BEGIN;

CREATE OR REPLACE FUNCTION public.admin_list_super_admin_accounts(session json)
RETURNS SETOF public.v_super_admin_account
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_sess jsonb := '{}'::jsonb;
  v_uid text := '';
  v_root_uid uuid;
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  IF session IS NOT NULL THEN
    v_sess := session::jsonb;
  END IF;

  v_uid := coalesce(v_sess->>'x-hasura-user-id', '');

  IF v_uid = '' THEN
    -- fallback to GUCs if session not provided
    v_uid := coalesce(nullif(current_setting('x-hasura-user-id', true), ''), v_uid);
  END IF;

  IF v_uid = '' THEN
    RETURN;
  END IF;

  SELECT u.id INTO v_root_uid
  FROM auth.users u
  WHERE lower((u.email)::text) = lower('elmam.clinic.c.s@elmam.com')
  LIMIT 1;

  IF v_root_uid IS NULL OR v_uid <> v_root_uid::text THEN
    RETURN;
  END IF;

  IF to_regclass('auth.user_roles') IS NOT NULL THEN
    RETURN QUERY
    SELECT
      lower((u.email)::text) AS email,
      u.id AS user_uid,
      coalesce(sa.created_at, u.created_at) AS created_at,
      coalesce(sa.disabled, u.disabled, false) AS disabled,
      coalesce(sa.default_role, 'superadmin') AS default_role,
      coalesce(p.allowed_tabs, v_default) AS allowed_tabs,
      true AS has_user
    FROM auth.user_roles ur
    JOIN auth.users u
      ON u.id = ur.user_id
    LEFT JOIN public.super_admins sa
      ON sa.user_uid = u.id OR lower(sa.email) = lower((u.email)::text)
    LEFT JOIN public.super_admin_tab_permissions p
      ON p.user_uid = u.id
    WHERE ur.role = 'superadmin'
    ORDER BY coalesce(sa.created_at, u.created_at) DESC;
  ELSE
    RETURN QUERY
    SELECT
      sa.email,
      sa.user_uid,
      sa.created_at,
      sa.disabled,
      sa.default_role,
      coalesce(p.allowed_tabs, v_default) AS allowed_tabs,
      (sa.user_uid IS NOT NULL) AS has_user
    FROM public.super_admins sa
    LEFT JOIN public.super_admin_tab_permissions p
      ON p.user_uid = sa.user_uid
    ORDER BY sa.created_at DESC;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts(json) TO PUBLIC;

COMMIT;
