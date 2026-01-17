-- Restore list_employees_with_email definition without explicit RLS bypass.
CREATE OR REPLACE FUNCTION public.list_employees_with_email(p_account uuid)
RETURNS SETOF public.v_list_employees_with_email
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  caller_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  can_manage boolean;
  is_super boolean := public.fn_is_super_admin();
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.account_users
    WHERE account_id = p_account
      AND user_uid = caller_uid
      AND lower(coalesce(role, '')) IN ('owner','admin')
      AND coalesce(disabled,false) = false
  ) INTO can_manage;

  IF NOT (can_manage OR is_super) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT
    au.user_uid,
    coalesce(u.email, au.email),
    au.role,
    coalesce(au.disabled,false) AS disabled,
    au.created_at,
    e.id AS employee_id,
    d.id AS doctor_id
  FROM public.account_users au
  LEFT JOIN auth.users u ON u.id = au.user_uid
  LEFT JOIN public.employees e ON e.user_uid = au.user_uid
  LEFT JOIN public.doctors d ON d.user_uid = au.user_uid
  WHERE au.account_id = p_account
  ORDER BY au.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.list_employees_with_email(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_employees_with_email(uuid) TO PUBLIC;
