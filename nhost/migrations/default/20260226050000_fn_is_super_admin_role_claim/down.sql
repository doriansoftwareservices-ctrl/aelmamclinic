-- Revert to previous definition (without role-claim shortcut)
CREATE OR REPLACE FUNCTION public.fn_is_super_admin()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_role text := current_setting('request.jwt.claim.role', true);
  v_hasura_user text := current_setting('hasura.user', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  claims jsonb := '{}'::jsonb;
  v_uid uuid;
  v_email text := '';
  v_lookup_email text;
BEGIN
  -- Admin-secret sessions
  IF v_hasura_user = 'admin' THEN
    RETURN true;
  END IF;

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
$function$;
