BEGIN;

CREATE TABLE IF NOT EXISTS public.superadmin_whitelist (
  email text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.superadmin_whitelist(email)
VALUES (lower('elmam.clinic.c.s@elmam.com'))
ON CONFLICT (email) DO NOTHING;

DO $$
DECLARE
  v_root_uid uuid;
BEGIN
  SELECT u.id INTO v_root_uid
  FROM auth.users u
  WHERE lower((u.email)::text) = lower('elmam.clinic.c.s@elmam.com')
  LIMIT 1;

  IF v_root_uid IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.super_admins
     SET user_uid = v_root_uid
   WHERE lower(email) = lower('elmam.clinic.c.s@elmam.com');

  INSERT INTO public.super_admins(email, user_uid, disabled, default_role, created_at)
  SELECT lower('elmam.clinic.c.s@elmam.com'), v_root_uid, false, 'superadmin', now()
  WHERE NOT EXISTS (
    SELECT 1 FROM public.super_admins WHERE lower(email) = lower('elmam.clinic.c.s@elmam.com')
  );
END $$;

CREATE OR REPLACE FUNCTION public.request_uid_text()
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_uid text := '';
  v_hasura jsonb := '{}'::jsonb;
  v_claims jsonb := '{}'::jsonb;
  v_headers jsonb := '{}'::jsonb;
BEGIN
  v_uid := coalesce(nullif(current_setting('x-hasura-user-id', true), ''), '');
  IF v_uid <> '' THEN RETURN v_uid; END IF;

  BEGIN
    v_hasura := nullif(current_setting('hasura.user', true), '')::jsonb;
  EXCEPTION WHEN others THEN
    v_hasura := '{}'::jsonb;
  END;
  v_uid := coalesce(v_hasura->>'x-hasura-user-id', '');
  IF v_uid <> '' THEN RETURN v_uid; END IF;

  BEGIN
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN others THEN
    v_headers := '{}'::jsonb;
  END;
  v_uid := coalesce(v_headers->>'x-hasura-user-id', '');
  IF v_uid <> '' THEN RETURN v_uid; END IF;

  BEGIN
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  EXCEPTION WHEN others THEN
    v_claims := '{}'::jsonb;
  END;

  IF v_claims = '{}'::jsonb THEN
    BEGIN
      v_claims := nullif(current_setting('jwt.claims', true), '')::jsonb;
    EXCEPTION WHEN others THEN
      v_claims := '{}'::jsonb;
    END;
  END IF;

  v_uid := coalesce(
    v_claims #>> '{https://hasura.io/jwt/claims,x-hasura-user-id}',
    v_claims->>'sub',
    ''
  );
  RETURN coalesce(v_uid, '');
END;
$$;

REVOKE ALL ON FUNCTION public.request_uid_text() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_uid_text() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_is_root_email()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid text := '';
  v_root_uid uuid;
BEGIN
  v_uid := public.request_uid_text();
  IF v_uid IS NULL OR v_uid = '' THEN
    RETURN false;
  END IF;

  SELECT u.id INTO v_root_uid
  FROM auth.users u
  WHERE lower((u.email)::text) = lower('elmam.clinic.c.s@elmam.com')
  LIMIT 1;

  RETURN (v_root_uid IS NOT NULL AND v_uid = v_root_uid::text);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_is_root_email() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_is_root_email() TO PUBLIC;

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
  IF public.admin_is_root_email() IS DISTINCT FROM true THEN
    RETURN;
  END IF;

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
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_super_admin_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_super_admin_accounts() TO PUBLIC;

COMMIT;
