BEGIN;

-- Interactive privileged RPCs use the active UID registry. Email/role claims
-- cannot revive a disabled or removed administrator. Keep the existing
-- trusted service_role maintenance path for legacy server integrations.
CREATE OR REPLACE FUNCTION public.fn_is_super_admin()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth, pg_temp AS $function$
DECLARE
  actor uuid;
BEGIN
  IF current_setting('request.jwt.claim.role', true) = 'service_role' THEN
    RETURN true;
  END IF;
  BEGIN
    actor := nullif(public.request_uid_text(), '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN false;
  END;
  IF actor IS NULL THEN RETURN false; END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.super_admins sa
    JOIN auth.users u ON u.id = sa.user_uid
    WHERE sa.user_uid = actor AND sa.disabled IS DISTINCT FROM true
      AND u.disabled IS DISTINCT FROM true
  );
END
$function$;
REVOKE ALL ON FUNCTION public.fn_is_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin() TO PUBLIC;

COMMIT;
