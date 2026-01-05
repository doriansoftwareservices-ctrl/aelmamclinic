BEGIN;

-- Superadmin-only: account member counts per account.
CREATE OR REPLACE FUNCTION public.admin_dashboard_account_member_counts(
  hasura_session json,
  p_only_active boolean DEFAULT true
)
RETURNS TABLE(
  account_id uuid,
  account_name text,
  owners_count bigint,
  admins_count bigint,
  employees_count bigint,
  total_members bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT
    au.account_id,
    a.name AS account_name,
    sum((lower(au.role) = 'owner')::int) AS owners_count,
    sum((lower(au.role) = 'admin')::int) AS admins_count,
    sum((lower(au.role) = 'employee')::int) AS employees_count,
    count(*) AS total_members
  FROM public.account_users au
  JOIN public.accounts a ON a.id = au.account_id
  WHERE (p_only_active IS DISTINCT FROM true)
     OR coalesce(au.disabled, false) = false
  GROUP BY au.account_id, a.name
  ORDER BY total_members DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_account_member_counts(json, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_account_member_counts(json, boolean) TO PUBLIC;

-- Superadmin-only: list members (optionally filter by account).
CREATE OR REPLACE FUNCTION public.admin_dashboard_account_members(
  hasura_session json,
  p_account uuid DEFAULT NULL,
  p_only_active boolean DEFAULT true
)
RETURNS TABLE(
  account_id uuid,
  account_name text,
  user_uid uuid,
  email text,
  role text,
  disabled boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT
    au.account_id,
    a.name AS account_name,
    au.user_uid,
    au.email,
    au.role,
    au.disabled,
    au.created_at
  FROM public.account_users au
  JOIN public.accounts a ON a.id = au.account_id
  WHERE (p_account IS NULL OR au.account_id = p_account)
    AND ((p_only_active IS DISTINCT FROM true)
      OR coalesce(au.disabled, false) = false)
  ORDER BY a.name, au.role, au.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_account_members(json, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_account_members(json, uuid, boolean) TO PUBLIC;

COMMIT;
