BEGIN;

CREATE TABLE IF NOT EXISTS public.employee_seat_pricing (
  seat_kind text PRIMARY KEY,
  price_usd numeric(12,2) NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NULL
);

INSERT INTO public.employee_seat_pricing(seat_kind, price_usd)
VALUES ('extra', 50)
ON CONFLICT (seat_kind) DO NOTHING;

CREATE OR REPLACE VIEW public.v_employee_seat_pricing AS
SELECT
  seat_kind,
  price_usd,
  updated_at,
  updated_by
FROM public.employee_seat_pricing;

CREATE OR REPLACE FUNCTION public.employee_seat_price(p_seat_kind text)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_price numeric;
BEGIN
  SELECT price_usd INTO v_price
  FROM public.employee_seat_pricing
  WHERE seat_kind = p_seat_kind;

  IF v_price IS NULL THEN
    v_price := 50;
  END IF;

  RETURN v_price;
END;
$$;
REVOKE ALL ON FUNCTION public.employee_seat_price(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.employee_seat_price(text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_get_employee_seat_pricing()
RETURNS SETOF public.v_employee_seat_pricing
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT * FROM public.v_employee_seat_pricing;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_get_employee_seat_pricing() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_get_employee_seat_pricing() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_set_employee_seat_price(
  p_seat_kind text,
  p_price numeric
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RETURN QUERY SELECT false, 'forbidden', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_seat_kind IS NULL OR trim(p_seat_kind) = '' THEN
    RETURN QUERY SELECT false, 'seat_kind_required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_price IS NULL OR p_price < 0 THEN
    RETURN QUERY SELECT false, 'invalid_price', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  BEGIN
    v_uid := nullif(public.request_uid_text(), '')::uuid;
  EXCEPTION WHEN others THEN
    v_uid := NULL;
  END;

  INSERT INTO public.employee_seat_pricing(seat_kind, price_usd, updated_at, updated_by)
  VALUES (trim(p_seat_kind), p_price, now(), v_uid)
  ON CONFLICT (seat_kind) DO UPDATE
    SET price_usd = EXCLUDED.price_usd,
        updated_at = now(),
        updated_by = EXCLUDED.updated_by;

  RETURN QUERY SELECT true, NULL::text, NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_employee_seat_price(text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_employee_seat_price(text, numeric) TO PUBLIC;

-- Owner: extra seat request should use configurable price.
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

  SELECT count(*)
    INTO v_count
    FROM public.account_users au
   WHERE au.account_id = v_account
     AND lower(coalesce(au.role, '')) IN ('employee', 'admin')
     AND coalesce(au.disabled, false) = false;

  IF v_count < 5 THEN
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
