BEGIN;

CREATE OR REPLACE FUNCTION public.request_uid_text()
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_claims jsonb := '{}'::jsonb;
BEGIN
  BEGIN
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  EXCEPTION WHEN others THEN
    v_claims := '{}'::jsonb;
  END;

  RETURN coalesce(
    v_claims #>> '{https://hasura.io/jwt/claims,x-hasura-user-id}',
    v_claims->>'sub',
    ''
  );
END;
$$;

REVOKE ALL ON FUNCTION public.request_uid_text() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_uid_text() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_is_root_email()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claims jsonb;
  v_email text := '';
BEGIN
  v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_email := lower(trim(coalesce(
    v_claims #>> '{https://hasura.io/jwt/claims,x-hasura-user-email}',
    ''
  )));
  RETURN v_email = lower('elmam.clinic.c.s@elmam.com');
END;
$$;

REVOKE ALL ON FUNCTION public.admin_is_root_email() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_is_root_email() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_list_super_admin_accounts()
RETURNS SETOF public.v_super_admin_account
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_default text[] := ARRAY[
    'clinics','chats','subscriptions','payments','complaints','stats','members'
  ]::text[];
BEGIN
  IF public.admin_is_root_email() IS DISTINCT FROM true THEN
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

REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO PUBLIC;

COMMIT;
