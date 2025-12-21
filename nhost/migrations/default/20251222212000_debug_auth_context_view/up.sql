-- Expose debug_auth_context via a view-backed return type for Hasura.

CREATE OR REPLACE VIEW public.v_debug_auth_context AS
SELECT
  NULL::text AS hasura_user,
  NULL::text AS jwt_claims,
  NULL::text AS jwt_claim_sub,
  NULL::text AS jwt_claim_role,
  NULL::text AS request_uid
WHERE false;

DROP FUNCTION IF EXISTS public.debug_auth_context();

CREATE OR REPLACE FUNCTION public.debug_auth_context()
RETURNS SETOF public.v_debug_auth_context
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    current_setting('hasura.user', true) AS hasura_user,
    current_setting('request.jwt.claims', true) AS jwt_claims,
    current_setting('request.jwt.claim.sub', true) AS jwt_claim_sub,
    current_setting('request.jwt.claim.role', true) AS jwt_claim_role,
    public.request_uid_text() AS request_uid;
$$;

REVOKE ALL ON FUNCTION public.debug_auth_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.debug_auth_context() TO PUBLIC;
