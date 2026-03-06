BEGIN;

-- Revert to previous definitions from 20260209102000_fix_superadmin_runtime_guards
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
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := '';
  v_lookup_email text;
BEGIN
  IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
    BEGIN
      claims := raw_claims::jsonb;
    EXCEPTION WHEN others THEN
      claims := '{}'::jsonb;
    END;
  END IF;

  v_email := lower(
    coalesce(
      public.request_email_text(),
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-email',
      claims -> 'https://hasura.io/jwt/claims' ->> 'email',
      claims ->> 'email',
      ''
    )
  );

  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  IF v_uid IS NOT NULL THEN
    IF exists (
      select 1
        from public.super_admins sa
       where sa.user_uid = v_uid
    ) THEN
      RETURN true;
    END IF;
  END IF;

  IF v_email <> '' THEN
    IF exists (
      select 1
        from public.super_admins sa
       where lower(sa.email) = v_email
    ) THEN
      RETURN true;
    END IF;
  END IF;

  IF v_uid IS NOT NULL THEN
    select lower(u.email)
      into v_lookup_email
      from auth.users u
     where u.id = v_uid
     limit 1;

    IF v_lookup_email IS NOT NULL THEN
      IF exists (
        select 1
          from public.super_admins sa
         where lower(sa.email) = v_lookup_email
      ) THEN
        RETURN true;
      END IF;
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
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := '';
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RETURN false;
  END IF;

  IF v_uid IS NOT NULL THEN
    select lower(u.email)
      into v_email
      from auth.users u
     where u.id = v_uid
     limit 1;
  END IF;

  v_email := lower(
    coalesce(
      v_email,
      public.request_email_text(),
      ''
    )
  );

  RETURN v_email = 'elmam.clinic.c.s@elmam.com';
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_root_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_root_super_admin() TO PUBLIC;

COMMIT;
