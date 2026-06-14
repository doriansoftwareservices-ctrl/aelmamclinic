BEGIN;

-- Roll back only the root-email predicate to the legacy value.
-- Data created for valid superadmin accounts is intentionally preserved.
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
     LIMIT 1;
  END IF;

  v_email := lower(coalesce(v_email, public.request_email_text(), ''));

  RETURN v_email = lower('elmam.clinic.c.s@elmam.com');
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_root_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_root_super_admin() TO PUBLIC;

COMMIT;
