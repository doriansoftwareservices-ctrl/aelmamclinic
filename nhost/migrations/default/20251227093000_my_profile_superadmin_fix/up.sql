CREATE OR REPLACE FUNCTION public.my_profile()
RETURNS SETOF public.v_my_profile
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  WITH sa AS (
    SELECT public.fn_is_super_admin() AS is_sa
  ),
  me AS (
    SELECT
      u.id,
      u.email,
      p.role AS profile_role,
      p.account_id AS profile_account_id,
      p.display_name,
      (
        SELECT array_agg(au.account_id ORDER BY au.created_at DESC)
        FROM public.account_users au
        WHERE au.user_uid = u.id
          AND coalesce(au.disabled, false) = false
      ) AS membership_accounts,
      (
        SELECT au.role
        FROM public.account_users au
        WHERE au.user_uid = u.id
          AND coalesce(au.disabled, false) = false
        ORDER BY au.created_at DESC
        LIMIT 1
      ) AS membership_role
    FROM auth.users u
    LEFT JOIN public.profiles p ON p.id = u.id
    WHERE u.id = nullif(public.request_uid_text(), '')::uuid
  )
  SELECT
    me.id,
    me.email,
    CASE
      WHEN sa.is_sa THEN 'superadmin'
      ELSE coalesce(me.profile_role, me.membership_role, 'employee')
    END AS role,
    CASE
      WHEN sa.is_sa THEN NULL
      ELSE coalesce(
        me.profile_account_id,
        me.membership_accounts[1],
        (SELECT account_id FROM public.my_account_id() LIMIT 1)
      )
    END AS account_id,
    me.display_name,
    coalesce(me.membership_accounts, array[]::uuid[]) AS account_ids
  FROM me, sa;
$$;
