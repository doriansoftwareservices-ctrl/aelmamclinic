-- Prefer owner/admin roles and fall back to profiles for my_profile
CREATE OR REPLACE FUNCTION public.my_profile(hasura_session json)
RETURNS SETOF public.v_my_profile
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT NULLIF(public.request_uid_text(), '')::uuid AS uid
  ),
  au AS (
    SELECT
      account_id,
      role,
      disabled,
      created_at,
      CASE
        WHEN role = 'owner' THEN 3
        WHEN role = 'admin' THEN 2
        WHEN role = 'employee' THEN 1
        ELSE 0
      END AS role_rank
    FROM public.account_users
    WHERE user_uid = (SELECT uid FROM me)
      AND COALESCE(disabled, false) = false
  ),
  best AS (
    SELECT account_id, role
    FROM au
    ORDER BY role_rank DESC, created_at DESC
    LIMIT 1
  )
  SELECT
    p.id,
    p.email,
    COALESCE((SELECT role FROM best), p.role, 'employee') AS role,
    COALESCE((SELECT account_id FROM best), p.account_id) AS account_id,
    p.display_name,
    COALESCE((SELECT array_agg(account_id) FROM au), p.account_ids, ARRAY[]::uuid[]) AS account_ids
  FROM public.profiles p
  JOIN me ON p.id = me.uid;
$$;
