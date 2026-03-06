BEGIN;

-- 1) Add/Update new plans
INSERT INTO public.subscription_plans(code, name, price_usd, duration_months, is_active)
VALUES
  ('month_plus', 'MONTH_PLUS', 99, 1, true),
  ('month_pro', 'MONTH_PRO', 150, 1, true),
  ('year_plus', 'YEAR_PLUS', 999, 12, true),
  ('year_pro', 'YEAR_PRO', 1500, 12, true)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name,
      price_usd = EXCLUDED.price_usd,
      duration_months = EXCLUDED.duration_months,
      is_active = EXCLUDED.is_active,
      updated_at = now();

-- 2) Plan features: remove lab/radiology from month/year
DELETE FROM public.plan_features
WHERE plan_code IN ('month', 'year')
  AND feature_key = 'lab_radiology';

-- 3) Reset features for new plans (idempotent)
DELETE FROM public.plan_features
WHERE plan_code IN ('month_plus', 'month_pro', 'year_plus', 'year_pro');

-- 4) Copy base features from existing month/year
INSERT INTO public.plan_features(plan_code, feature_key)
SELECT 'month_plus', pf.feature_key
FROM public.plan_features pf
WHERE pf.plan_code = 'month'
ON CONFLICT DO NOTHING;

INSERT INTO public.plan_features(plan_code, feature_key)
SELECT 'year_plus', pf.feature_key
FROM public.plan_features pf
WHERE pf.plan_code = 'year'
ON CONFLICT DO NOTHING;

INSERT INTO public.plan_features(plan_code, feature_key)
SELECT 'month_pro', pf.feature_key
FROM public.plan_features pf
WHERE pf.plan_code = 'month'
ON CONFLICT DO NOTHING;

INSERT INTO public.plan_features(plan_code, feature_key)
SELECT 'year_pro', pf.feature_key
FROM public.plan_features pf
WHERE pf.plan_code = 'year'
ON CONFLICT DO NOTHING;

-- 5) Pro plans include lab/radiology
INSERT INTO public.plan_features(plan_code, feature_key)
VALUES
  ('month_pro', 'lab_radiology'),
  ('year_pro', 'lab_radiology')
ON CONFLICT DO NOTHING;

-- 6) Update employee seat limits based on plan
CREATE OR REPLACE FUNCTION public.owner_create_employee_within_limit(
  hasura_session json,
  p_email text,
  p_password text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(hasura_session->>'x-hasura-user-id', '')::uuid;
  v_account uuid;
  v_role text;
  v_email text := lower(coalesce(trim(p_email), ''));
  v_password text := nullif(coalesce(trim(p_password), ''), '');
  v_emp_uid uuid;
  v_count integer := 0;
  v_plan text := 'free';
  v_limit integer := 5;
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not authenticated', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT public.my_account_id() INTO v_account;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT au.role
    INTO v_role
    FROM public.account_users au
   WHERE au.user_uid = v_uid
     AND au.account_id = v_account
     AND coalesce(au.disabled, false) = false
   LIMIT 1;

  IF v_role IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF lower(coalesce(v_role, '')) <> 'owner' THEN
    RETURN QUERY SELECT false, 'forbidden', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.account_is_paid(v_account) IS DISTINCT FROM true THEN
    RETURN QUERY SELECT false, 'plan is free', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT plan_code INTO v_plan FROM public.my_account_plan() LIMIT 1;
  v_limit := CASE lower(coalesce(v_plan, ''))
    WHEN 'month' THEN 5
    WHEN 'year' THEN 5
    WHEN 'month_plus' THEN 10
    WHEN 'year_plus' THEN 10
    WHEN 'month_pro' THEN 20
    WHEN 'year_pro' THEN 20
    ELSE 5
  END;

  SELECT count(*)
    INTO v_count
    FROM public.account_users au
   WHERE au.account_id = v_account
     AND lower(coalesce(au.role, '')) IN ('employee', 'admin')
     AND coalesce(au.disabled, false) = false;

  IF v_count >= v_limit THEN
    RETURN QUERY SELECT false, 'seat_limit_reached', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_email = '' OR v_password IS NULL THEN
    RETURN QUERY SELECT false, 'email and password are required', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  v_emp_uid := public.admin_resolve_or_create_auth_user(
    v_email,
    v_password,
    'employee'
  );

  IF v_emp_uid = v_uid THEN
    RETURN QUERY SELECT false, 'cannot_add_self', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  INSERT INTO public.account_users(account_id, user_uid, role, disabled, email)
  VALUES (v_account, v_emp_uid, 'employee', false, v_email)
  ON CONFLICT (account_id, user_uid) DO UPDATE
    SET role = excluded.role,
        disabled = excluded.disabled,
        email = COALESCE(excluded.email, public.account_users.email),
        updated_at = now();

  UPDATE public.profiles
     SET account_id = v_account,
         role = 'employee',
         email = v_email,
         disabled = false,
         updated_at = now()
   WHERE id = v_emp_uid;

  PERFORM public.auth_set_user_claims(v_emp_uid, 'employee', v_account);

  -- Create chat code for employee if paid
  PERFORM public.ensure_account_user_chat_code(v_account, v_emp_uid);

  RETURN QUERY SELECT true, NULL::text, v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, false;
END;
$$;
REVOKE ALL ON FUNCTION public.owner_create_employee_within_limit(json, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_create_employee_within_limit(json, text, text) TO PUBLIC;

-- Owner: request extra employee seat uses plan-based limits
CREATE OR REPLACE FUNCTION public.owner_request_extra_employee(
  hasura_session json,
  p_email text,
  p_password text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(hasura_session->>'x-hasura-user-id', '')::uuid;
  v_account uuid;
  v_role text;
  v_email text := lower(coalesce(trim(p_email), ''));
  v_password text := nullif(coalesce(trim(p_password), ''), '');
  v_emp_uid uuid;
  v_count integer := 0;
  v_exists boolean := false;
  v_price numeric := public.employee_seat_price('extra');
  v_plan text := 'free';
  v_limit integer := 5;
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not authenticated', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT public.my_account_id() INTO v_account;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT au.role
    INTO v_role
    FROM public.account_users au
   WHERE au.user_uid = v_uid
     AND au.account_id = v_account
     AND coalesce(au.disabled, false) = false
   LIMIT 1;

  IF v_role IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF lower(coalesce(v_role, '')) <> 'owner' THEN
    RETURN QUERY SELECT false, 'forbidden', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.account_is_paid(v_account) IS DISTINCT FROM true THEN
    RETURN QUERY SELECT false, 'plan is free', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT plan_code INTO v_plan FROM public.my_account_plan() LIMIT 1;
  v_limit := CASE lower(coalesce(v_plan, ''))
    WHEN 'month' THEN 5
    WHEN 'year' THEN 5
    WHEN 'month_plus' THEN 10
    WHEN 'year_plus' THEN 10
    WHEN 'month_pro' THEN 20
    WHEN 'year_pro' THEN 20
    ELSE 5
  END;

  SELECT count(*)
    INTO v_count
    FROM public.account_users au
   WHERE au.account_id = v_account
     AND lower(coalesce(au.role, '')) IN ('employee', 'admin')
     AND coalesce(au.disabled, false) = false;

  IF v_count < v_limit THEN
    RETURN QUERY SELECT false, 'seat_limit_not_reached', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_email = '' OR v_password IS NULL THEN
    RETURN QUERY SELECT false, 'email and password are required', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  v_emp_uid := public.admin_resolve_or_create_auth_user(
    v_email,
    v_password,
    'employee'
  );

  IF v_emp_uid = v_uid THEN
    RETURN QUERY SELECT false, 'cannot_add_self', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.account_users au
     WHERE au.account_id = v_account
       AND au.user_uid = v_emp_uid
       AND coalesce(au.disabled, false) = false
  ) THEN
    RETURN QUERY SELECT false, 'employee_already_active', v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, false;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
      FROM public.employee_seat_requests r
     WHERE r.account_id = v_account
       AND r.employee_user_uid = v_emp_uid
       AND r.status IN ('awaiting_payment', 'submitted', 'approved')
  ) INTO v_exists;

  IF v_exists THEN
    RETURN QUERY SELECT false, 'request_already_exists', v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, true;
    RETURN;
  END IF;

  INSERT INTO public.account_users(account_id, user_uid, role, disabled, email)
  VALUES (v_account, v_emp_uid, 'employee', true, v_email)
  ON CONFLICT (account_id, user_uid) DO UPDATE
    SET role = excluded.role,
        disabled = true,
        email = COALESCE(excluded.email, public.account_users.email),
        updated_at = now();

  UPDATE public.profiles
     SET account_id = v_account,
         role = 'employee',
         email = v_email,
         disabled = true,
         updated_at = now()
   WHERE id = v_emp_uid;

  PERFORM public.auth_set_user_claims(v_emp_uid, 'employee', v_account);

  INSERT INTO public.employee_seat_requests(
    account_id,
    requested_by_uid,
    employee_user_uid,
    employee_email,
    seat_kind,
    status,
    price_usd
  ) VALUES (
    v_account,
    v_uid,
    v_emp_uid,
    v_email,
    'extra',
    'awaiting_payment',
    v_price
  );

  RETURN QUERY SELECT true, NULL::text, v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, true;
END;
$$;
REVOKE ALL ON FUNCTION public.owner_request_extra_employee(json, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_request_extra_employee(json, text, text) TO PUBLIC;

COMMIT;
