-- Plan gating for employees + admin clinic view details

BEGIN;

-- 1) Helper: determine if account is on a paid plan (within grace)
CREATE OR REPLACE FUNCTION public.account_is_paid(p_account uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.account_subscriptions s
    JOIN public.subscription_plans p ON p.code = s.plan_code
    WHERE s.account_id = p_account
      AND s.status = 'active'
      AND lower(coalesce(s.plan_code, 'free')) <> 'free'
      AND (
        s.end_at IS NULL OR
        (s.end_at + (coalesce(p.grace_days, 0)::text || ' days')::interval) > now()
      )
    ORDER BY s.created_at DESC
    LIMIT 1
  );
$$;
REVOKE ALL ON FUNCTION public.account_is_paid(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.account_is_paid(uuid) TO PUBLIC;

-- 2) Gate account membership: employees blocked on FREE plans
CREATE OR REPLACE FUNCTION public.fn_is_account_member(p_account uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result boolean := false;
  elevated boolean := false;
  r record;
BEGIN
  IF p_account IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    EXECUTE 'set local role postgres';
    EXECUTE 'set local row_security = off';
    elevated := true;

    SELECT au.role, au.disabled
      INTO r
      FROM public.account_users au
     WHERE au.account_id = p_account
       AND au.user_uid::text = public.request_uid_text()::text
     LIMIT 1;

    IF r.role IS NULL THEN
      result := false;
    ELSIF COALESCE(r.disabled, false) = true THEN
      result := false;
    ELSIF lower(coalesce(r.role, '')) IN ('owner','superadmin') THEN
      result := true;
    ELSE
      result := public.account_is_paid(p_account);
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      IF elevated THEN
        BEGIN
          EXECUTE 'reset role';
        EXCEPTION
          WHEN OTHERS THEN NULL;
        END;
        elevated := false;
      END IF;
      RAISE;
  END;

  IF elevated THEN
    BEGIN
      EXECUTE 'reset role';
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
  END IF;

  RETURN COALESCE(result, false);
END;
$$;
REVOKE ALL ON FUNCTION public.fn_is_account_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_account_member(uuid) TO PUBLIC;

-- 3) Admin: block employee provisioning for FREE plan
DROP FUNCTION IF EXISTS public.admin_create_employee_full(uuid, text, text);
CREATE OR REPLACE FUNCTION public.admin_create_employee_full(
  p_account uuid,
  p_email text,
  p_password text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  normalized_email text := lower(coalesce(trim(p_email), ''));
  normalized_role text := 'employee';
  normalized_password text := nullif(coalesce(trim(p_password), ''), '');
  emp_uid uuid;
  account_exists boolean;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_account IS NULL THEN
    RETURN QUERY SELECT false, 'account_id is required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF normalized_email = '' THEN
    RETURN QUERY SELECT false, 'email is required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT EXISTS (
           SELECT 1 FROM public.accounts a WHERE a.id = p_account
         )
    INTO account_exists;

  IF NOT COALESCE(account_exists, false) THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.account_is_paid(p_account) IS DISTINCT FROM true THEN
    RETURN QUERY SELECT false, 'plan is free', p_account, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  emp_uid := public.admin_resolve_or_create_auth_user(
    normalized_email,
    normalized_password,
    normalized_role
  );

  PERFORM public.admin_attach_employee(p_account, emp_uid, normalized_role);

  UPDATE public.account_users
     SET email = normalized_email,
         role = normalized_role,
         disabled = false,
         updated_at = now()
   WHERE account_id = p_account
     AND user_uid = emp_uid;

  UPDATE public.profiles
     SET account_id = p_account,
         role = normalized_role,
         email = normalized_email,
         disabled = false,
         updated_at = now()
   WHERE id = emp_uid;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', p_account::text
         ),
         raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', p_account::text,
           'email_verified', true
         )
   WHERE id = emp_uid;

  RETURN QUERY SELECT true, NULL::text, p_account, emp_uid, NULL::uuid, normalized_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_create_employee_full(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO public;

-- 4) Admin clinics view with plan details
CREATE OR REPLACE VIEW public.v_admin_list_clinics AS
SELECT
  a.id,
  a.name,
  a.frozen,
  a.created_at,
  COALESCE(s.plan_code, 'free') AS plan_code,
  COALESCE(s.status, 'active') AS plan_status,
  s.end_at AS plan_end_at
FROM public.accounts a
LEFT JOIN LATERAL (
  SELECT s.plan_code, s.status, s.end_at
  FROM public.account_subscriptions s
  WHERE s.account_id = a.id
    AND s.status = 'active'
  ORDER BY s.created_at DESC
  LIMIT 1
) s ON true;

DROP FUNCTION IF EXISTS public.admin_list_clinics();
CREATE OR REPLACE FUNCTION public.admin_list_clinics()
RETURNS SETOF public.v_admin_list_clinics
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.v_admin_list_clinics
  ORDER BY created_at DESC;
$$;
REVOKE ALL ON FUNCTION public.admin_list_clinics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_clinics() TO PUBLIC;

-- 5) Respect grace period in my_account_plan
DROP FUNCTION IF EXISTS public.my_account_plan();
CREATE OR REPLACE FUNCTION public.my_account_plan()
RETURNS SETOF public.v_my_account_plan
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH acc AS (
    SELECT account_id
    FROM public.my_account_id()
    LIMIT 1
  ),
  active_sub AS (
    SELECT s.plan_code
    FROM public.account_subscriptions s
    JOIN public.subscription_plans p ON p.code = s.plan_code
    JOIN acc ON acc.account_id = s.account_id
    WHERE s.status = 'active'
      AND (
        s.end_at IS NULL OR
        (s.end_at + (coalesce(p.grace_days, 0)::text || ' days')::interval) > now()
      )
    ORDER BY s.created_at DESC
    LIMIT 1
  )
  SELECT COALESCE((SELECT plan_code FROM active_sub), 'free') AS plan_code;
$$;
REVOKE ALL ON FUNCTION public.my_account_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_plan() TO PUBLIC;

COMMIT;
