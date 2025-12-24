-- 20251220130000_fix_jwt_claims_json_cast.sql
-- Guard against missing/empty request.jwt.claims when casting to json.

CREATE OR REPLACE FUNCTION public.fn_is_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_role text := current_setting('request.jwt.claim.role', true);
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_email text := lower(
    coalesce(
      (nullif(current_setting('request.jwt.claims', true), '')::json ->> 'email'),
      ''
    )
  );
  v_lookup_email text;
BEGIN
  -- allow service_role and other elevated JWTs outright
  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  -- explicit super_admins mappings by uid
  IF v_uid IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
        FROM public.super_admins sa
       WHERE sa.user_uid = v_uid
    ) THEN
      RETURN true;
    END IF;
  END IF;

  -- explicit mappings by stored email
  IF v_email <> '' THEN
    IF EXISTS (
      SELECT 1
        FROM public.super_admins sa
       WHERE lower(sa.email) = v_email
    ) THEN
      RETURN true;
    END IF;
  END IF;

  -- fallback: fetch email from auth.users when JWT omitted it
  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email)
      INTO v_lookup_email
      FROM auth.users u
     WHERE u.id = v_uid
     LIMIT 1;

    IF v_lookup_email IS NOT NULL THEN
      IF EXISTS (
        SELECT 1
          FROM public.super_admins sa
         WHERE lower(sa.email) = v_lookup_email
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

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql()
RETURNS SETOF public.super_admins
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT sa.*
  FROM public.super_admins sa
  WHERE sa.user_uid = nullif(public.request_uid_text(), '')::uuid
     OR (sa.user_uid IS NULL AND lower(sa.email) =
         lower(
           coalesce(
             (nullif(current_setting('request.jwt.claims', true), '')::json ->> 'email'),
             ''
           )
         ))
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_gql() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_gql() TO PUBLIC;
