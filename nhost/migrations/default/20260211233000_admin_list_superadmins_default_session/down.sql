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
    v_uid := coalesce(nullif(current_setting('x-hasura-user-id', true), ''), '');
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
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts(json) TO PUBLIC;

COMMIT;
