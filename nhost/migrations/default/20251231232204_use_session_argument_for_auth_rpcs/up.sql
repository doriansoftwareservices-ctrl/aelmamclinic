-- Ensure return-type views exist
CREATE OR REPLACE VIEW public.v_debug_auth_context AS
SELECT
  NULL::text  AS hasura_user,
  NULL::text  AS jwt_claims,
  NULL::text  AS jwt_claim_sub,
  NULL::text  AS jwt_claim_role,
  NULL::text  AS request_uid
WHERE false;

CREATE OR REPLACE VIEW public.v_is_super_admin AS
SELECT NULL::boolean AS is_super_admin
WHERE false;

CREATE OR REPLACE VIEW public.v_my_account_id AS
SELECT NULL::uuid AS account_id
WHERE false;

CREATE OR REPLACE VIEW public.v_my_profile AS
SELECT
  NULL::uuid AS id,
  NULL::text AS email,
  NULL::text AS role,
  NULL::uuid AS account_id,
  NULL::text AS display_name,
  ARRAY[]::uuid[] AS account_ids
WHERE false;

-- Drop no-arg overloads to avoid ambiguity
DROP FUNCTION IF EXISTS public.debug_auth_context();
DROP FUNCTION IF EXISTS public.fn_is_super_admin_gql();
DROP FUNCTION IF EXISTS public.my_account_id();
DROP FUNCTION IF EXISTS public.my_profile();

-- Recreate with hasura_session json
CREATE OR REPLACE FUNCTION public.debug_auth_context(hasura_session json)
RETURNS SETOF public.v_debug_auth_context
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT
    nullif(hasura_session->>'x-hasura-user-id','')                         AS request_uid,
    nullif(hasura_session->>'x-hasura-user-id','')                         AS jwt_claim_sub,
    hasura_session::text                                                   AS jwt_claims,
    hasura_session::text                                                   AS hasura_user,
    coalesce(hasura_session->>'x-hasura-role','')                          AS jwt_claim_role;
$$;

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_gql(hasura_session json)
RETURNS SETOF public.v_is_super_admin
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, auth
AS $$
  WITH uid AS (
    SELECT nullif(hasura_session->>'x-hasura-user-id','')::uuid AS id
  ),
  em AS (
    SELECT lower(u.email) AS email
    FROM auth.users u
    JOIN uid ON uid.id = u.id
    LIMIT 1
  )
  SELECT (
    EXISTS (
      SELECT 1 FROM public.super_admins s, uid, em
      WHERE (s.user_uid IS NOT NULL AND s.user_uid = uid.id)
         OR (s.email IS NOT NULL AND lower(s.email) = em.email)
    )
  ) AS is_super_admin;
$$;

CREATE OR REPLACE FUNCTION public.my_account_id(hasura_session json)
RETURNS SETOF public.v_my_account_id
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT au.account_id
  FROM public.account_users au
  WHERE au.user_uid = nullif(hasura_session->>'x-hasura-user-id','')::uuid
    AND coalesce(au.disabled,false) = false
  ORDER BY au.created_at DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.my_profile(hasura_session json)
RETURNS SETOF public.v_my_profile
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, auth
AS $$
  WITH me AS (
    SELECT u.id, lower(u.email) AS email
    FROM auth.users u
    WHERE u.id = nullif(hasura_session->>'x-hasura-user-id','')::uuid
    LIMIT 1
  ),
  membership AS (
    SELECT
      au.user_uid,
      (SELECT array_agg(au2.account_id ORDER BY au2.created_at DESC)
         FROM public.account_users au2
        WHERE au2.user_uid = au.user_uid
          AND coalesce(au2.disabled,false) = false
      ) AS account_ids,
      (SELECT au2.role
         FROM public.account_users au2
        WHERE au2.user_uid = au.user_uid
          AND coalesce(au2.disabled,false) = false
        ORDER BY au2.created_at DESC
        LIMIT 1
      ) AS role,
      (SELECT au2.account_id
         FROM public.account_users au2
        WHERE au2.user_uid = au.user_uid
          AND coalesce(au2.disabled,false) = false
        ORDER BY au2.created_at DESC
        LIMIT 1
      ) AS account_id
    FROM public.account_users au
    WHERE au.user_uid = (SELECT id FROM me)
    LIMIT 1
  )
  SELECT
    me.id,
    me.email,
    CASE
      WHEN (SELECT is_super_admin FROM public.fn_is_super_admin_gql(hasura_session) LIMIT 1) THEN 'superadmin'
      ELSE coalesce(membership.role, 'employee')
    END AS role,
    membership.account_id,
    NULL::text AS display_name,
    coalesce(membership.account_ids, array[]::uuid[]) AS account_ids
  FROM me
  LEFT JOIN membership ON membership.user_uid = me.id;
$$;
