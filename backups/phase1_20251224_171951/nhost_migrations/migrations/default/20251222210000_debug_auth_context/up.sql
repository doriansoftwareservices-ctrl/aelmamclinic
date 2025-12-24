-- Expose the raw auth context for debugging JWT/session propagation.

CREATE OR REPLACE FUNCTION public.debug_auth_context()
RETURNS TABLE (
  hasura_user text,
  jwt_claims text,
  jwt_claim_sub text,
  jwt_claim_role text,
  request_uid text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    current_setting('hasura.user', true),
    current_setting('request.jwt.claims', true),
    current_setting('request.jwt.claim.sub', true),
    current_setting('request.jwt.claim.role', true),
    public.request_uid_text();
$$;

REVOKE ALL ON FUNCTION public.debug_auth_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.debug_auth_context() TO PUBLIC;
