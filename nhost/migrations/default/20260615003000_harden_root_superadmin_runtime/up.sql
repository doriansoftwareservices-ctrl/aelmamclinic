BEGIN;

-- Keep backend root checks aligned with the recreated Nhost project.
-- This migration is idempotent and does not delete or downgrade any existing account.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.super_admins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  account_id uuid,
  device_id text,
  local_id bigint,
  email text,
  user_uid uuid,
  disabled boolean NOT NULL DEFAULT false,
  default_role text NOT NULL DEFAULT 'superadmin',
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.super_admins
  ADD COLUMN IF NOT EXISTS account_id uuid,
  ADD COLUMN IF NOT EXISTS device_id text,
  ADD COLUMN IF NOT EXISTS local_id bigint,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS user_uid uuid,
  ADD COLUMN IF NOT EXISTS disabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS default_role text NOT NULL DEFAULT 'superadmin',
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE IF NOT EXISTS public.superadmin_whitelist (
  email text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.super_admin_tab_permissions (
  user_uid uuid PRIMARY KEY,
  allowed_tabs text[] NOT NULL DEFAULT ARRAY[
    'clinics','chats','support_ratings','subscriptions','payments','complaints','stats','members'
  ]::text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.super_admin_tab_permissions
  ALTER COLUMN allowed_tabs
  SET DEFAULT ARRAY[
    'clinics','chats','support_ratings','subscriptions','payments','complaints','stats','members'
  ]::text[];

INSERT INTO auth.roles(role)
SELECT role
FROM unnest(ARRAY['user','me','owner','employee','admin','superadmin']::text[]) AS role
ON CONFLICT DO NOTHING;

-- If the root user already exists, make it a complete authenticated superadmin.
UPDATE auth.users
SET default_role = 'superadmin',
    email_verified = true,
    disabled = false,
    metadata = coalesce(metadata, '{}'::jsonb)
      || jsonb_build_object('role', 'superadmin', 'root', true, 'source', 'migration:20260615003000'),
    updated_at = now()
WHERE lower(email) = lower('elmamclinic.admin@elmam.com');

INSERT INTO auth.user_roles(user_id, role)
SELECT u.id, role
FROM auth.users u
CROSS JOIN unnest(ARRAY['user','me','superadmin']::text[]) AS role
WHERE lower(u.email) = lower('elmamclinic.admin@elmam.com')
ON CONFLICT DO NOTHING;

INSERT INTO public.super_admins(email, user_uid, disabled, default_role, updated_at)
SELECT lower('elmamclinic.admin@elmam.com'), u.id, false, 'superadmin', now()
FROM auth.users u
WHERE lower(u.email) = lower('elmamclinic.admin@elmam.com')
  AND NOT EXISTS (
    SELECT 1
    FROM public.super_admins sa
    WHERE lower(coalesce(sa.email, '')) = lower('elmamclinic.admin@elmam.com')
       OR sa.user_uid = u.id
  );

UPDATE public.super_admins sa
SET email = lower('elmamclinic.admin@elmam.com'),
    user_uid = u.id,
    disabled = false,
    default_role = 'superadmin',
    updated_at = now()
FROM auth.users u
WHERE lower(u.email) = lower('elmamclinic.admin@elmam.com')
  AND (
    lower(coalesce(sa.email, '')) = lower('elmamclinic.admin@elmam.com')
    OR sa.user_uid = u.id
  );

INSERT INTO public.superadmin_whitelist(email)
VALUES (lower('elmamclinic.admin@elmam.com'))
ON CONFLICT (email) DO NOTHING;

INSERT INTO public.super_admin_tab_permissions(user_uid, allowed_tabs, updated_at)
SELECT
  u.id,
  ARRAY['clinics','chats','support_ratings','subscriptions','payments','complaints','stats','members']::text[],
  now()
FROM auth.users u
WHERE lower(u.email) = lower('elmamclinic.admin@elmam.com')
ON CONFLICT (user_uid) DO UPDATE
SET allowed_tabs = excluded.allowed_tabs,
    updated_at = excluded.updated_at;

CREATE OR REPLACE FUNCTION public.fn_is_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_role text := current_setting('request.jwt.claim.role', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  claims jsonb := '{}'::jsonb;
  v_uid uuid;
  v_email text := '';
  v_lookup_email text;
BEGIN
  BEGIN
    v_uid := nullif(public.request_uid_text(), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
    BEGIN
      claims := raw_claims::jsonb;
    EXCEPTION WHEN others THEN
      claims := '{}'::jsonb;
    END;
  END IF;

  v_email := lower(coalesce(
    public.request_email_text(),
    claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-email',
    claims -> 'https://hasura.io/jwt/claims' ->> 'email',
    claims ->> 'email',
    ''
  ));

  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  IF v_uid IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.super_admins sa
    WHERE sa.user_uid = v_uid
      AND coalesce(sa.disabled, false) = false
  ) THEN
    RETURN true;
  END IF;

  IF v_email <> '' AND EXISTS (
    SELECT 1
    FROM public.super_admins sa
    WHERE lower(sa.email) = v_email
      AND coalesce(sa.disabled, false) = false
  ) THEN
    RETURN true;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email)
      INTO v_lookup_email
      FROM auth.users u
     WHERE u.id = v_uid
       AND coalesce(u.disabled, false) = false
     LIMIT 1;

    IF v_lookup_email IS NOT NULL AND EXISTS (
      SELECT 1
      FROM public.super_admins sa
      WHERE lower(sa.email) = v_lookup_email
        AND coalesce(sa.disabled, false) = false
    ) THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.fn_is_root_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid;
  v_email text := '';
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RETURN false;
  END IF;

  BEGIN
    v_uid := nullif(public.request_uid_text(), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email)
      INTO v_email
      FROM auth.users u
     WHERE u.id = v_uid
       AND coalesce(u.disabled, false) = false
     LIMIT 1;
  END IF;

  v_email := lower(coalesce(v_email, public.request_email_text(), ''));

  RETURN v_email = lower('elmamclinic.admin@elmam.com');
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_root_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_root_super_admin() TO PUBLIC;

COMMIT;
