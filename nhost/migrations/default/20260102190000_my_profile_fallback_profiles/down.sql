BEGIN;

-- Revert to previous definition without profiles fallback.
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
      WHEN (SELECT is_super_admin FROM public.fn_is_super_admin_gql(hasura_session) LIMIT 1)
        THEN 'superadmin'
      ELSE coalesce(membership.role, 'employee')
    END AS role,
    membership.account_id,
    NULL::text AS display_name,
    coalesce(membership.account_ids, array[]::uuid[]) AS account_ids
  FROM me
  LEFT JOIN membership ON membership.user_uid = me.id;
$$;

COMMIT;
