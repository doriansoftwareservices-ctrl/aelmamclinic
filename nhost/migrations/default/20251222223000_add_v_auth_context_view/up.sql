-- Add a view that exposes auth session data through GraphQL.

CREATE OR REPLACE VIEW public.v_auth_context AS
SELECT
  current_setting('hasura.user', true) AS hasura_user,
  current_setting('request.jwt.claims', true) AS jwt_claims,
  current_setting('request.jwt.claim.sub', true) AS jwt_claim_sub,
  current_setting('request.jwt.claim.role', true) AS jwt_claim_role,
  public.request_uid_text() AS request_uid;
