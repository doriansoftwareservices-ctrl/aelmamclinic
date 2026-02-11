BEGIN;

-- Ensure whitelist table exists for superadmin role guard.
CREATE TABLE IF NOT EXISTS public.superadmin_whitelist (
  email text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Seed whitelist from existing super admins + ensure root is present.
INSERT INTO public.superadmin_whitelist(email)
SELECT lower(sa.email)
FROM public.super_admins sa
WHERE sa.email IS NOT NULL AND sa.email <> ''
ON CONFLICT (email) DO NOTHING;

INSERT INTO public.superadmin_whitelist(email)
VALUES (lower('elmam.clinic.c.s@elmam.com'))
ON CONFLICT (email) DO NOTHING;

-- Root-only helper using user UID (claims email may be missing).
CREATE OR REPLACE FUNCTION public.admin_is_root_email()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid_text text := '';
  v_uid uuid;
  v_root_uid uuid;
  v_email text := '';
BEGIN
  v_uid_text := public.request_uid_text();
  BEGIN
    v_uid := nullif(v_uid_text, '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  SELECT sa.user_uid
    INTO v_root_uid
    FROM public.super_admins sa
   WHERE lower(sa.email) = lower('elmam.clinic.c.s@elmam.com')
     AND coalesce(sa.disabled,false) = false
   ORDER BY sa.created_at ASC
   LIMIT 1;

  IF v_root_uid IS NOT NULL AND v_uid IS NOT NULL AND v_uid = v_root_uid THEN
    RETURN true;
  END IF;

  v_email := lower(trim(coalesce(
    current_setting('request.jwt.claims', true)::jsonb #>> '{https://hasura.io/jwt/claims,x-hasura-user-email}',
    ''
  )));

  RETURN v_email = lower('elmam.clinic.c.s@elmam.com');
END;
$$;
REVOKE ALL ON FUNCTION public.admin_is_root_email() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_is_root_email() TO PUBLIC;

-- Root-only: list super admins without touching auth.users.
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
