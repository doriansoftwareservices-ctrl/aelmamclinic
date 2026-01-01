BEGIN;

-- Seat requests for extra employee accounts.
CREATE TABLE IF NOT EXISTS public.employee_seat_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  requested_by_uid uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  employee_user_uid uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  employee_email text NOT NULL,
  seat_kind text NOT NULL DEFAULT 'extra',
  status text NOT NULL DEFAULT 'awaiting_payment',
  price_usd numeric NOT NULL DEFAULT 25,
  payment_method_id uuid NULL REFERENCES public.payment_methods(id),
  receipt_file_id text NULL,
  admin_note text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_seat_requests_status_check
    CHECK (status IN ('awaiting_payment', 'submitted', 'approved', 'rejected')),
  CONSTRAINT employee_seat_requests_kind_check
    CHECK (seat_kind IN ('extra'))
);

CREATE UNIQUE INDEX IF NOT EXISTS employee_seat_requests_account_user_uidx
  ON public.employee_seat_requests (account_id, employee_user_uid);
CREATE INDEX IF NOT EXISTS employee_seat_requests_account_idx
  ON public.employee_seat_requests (account_id);
CREATE INDEX IF NOT EXISTS employee_seat_requests_status_idx
  ON public.employee_seat_requests (status);

DROP TRIGGER IF EXISTS employee_seat_requests_set_updated_at
  ON public.employee_seat_requests;
CREATE TRIGGER employee_seat_requests_set_updated_at
BEFORE UPDATE ON public.employee_seat_requests
FOR EACH ROW
EXECUTE FUNCTION public.tg_touch_updated_at();

-- Owner: create employee within free seats limit (5).
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
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not authenticated', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT au.account_id, au.role
    INTO v_account, v_role
    FROM public.account_users au
   WHERE au.user_uid = v_uid
     AND coalesce(au.disabled, false) = false
   ORDER BY au.created_at DESC
   LIMIT 1;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
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

  IF v_count >= 5 THEN
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

  RETURN QUERY SELECT true, NULL::text, v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, false;
END;
$$;
REVOKE ALL ON FUNCTION public.owner_create_employee_within_limit(json, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_create_employee_within_limit(json, text, text) TO PUBLIC;

-- Owner: request an extra employee (frozen until payment approved).
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
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not authenticated', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT au.account_id, au.role
    INTO v_account, v_role
    FROM public.account_users au
   WHERE au.user_uid = v_uid
     AND coalesce(au.disabled, false) = false
   ORDER BY au.created_at DESC
   LIMIT 1;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
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
    25
  );

  RETURN QUERY SELECT true, NULL::text, v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, true;
END;
$$;
REVOKE ALL ON FUNCTION public.owner_request_extra_employee(json, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_request_extra_employee(json, text, text) TO PUBLIC;

-- Owner: submit payment receipt for extra employee request.
CREATE OR REPLACE FUNCTION public.owner_submit_employee_seat_payment(
  hasura_session json,
  p_request_id uuid,
  p_payment_method_id uuid DEFAULT NULL,
  p_receipt_file_id text DEFAULT NULL
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
  v_request record;
  v_receipt text := nullif(trim(coalesce(p_receipt_file_id, '')), '');
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not authenticated', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT au.account_id, au.role
    INTO v_account, v_role
    FROM public.account_users au
   WHERE au.user_uid = v_uid
     AND coalesce(au.disabled, false) = false
   ORDER BY au.created_at DESC
   LIMIT 1;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'account not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF lower(coalesce(v_role, '')) <> 'owner' THEN
    RETURN QUERY SELECT false, 'forbidden', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_receipt IS NULL THEN
    RETURN QUERY SELECT false, 'receipt is required', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT *
    INTO v_request
    FROM public.employee_seat_requests r
   WHERE r.id = p_request_id
   LIMIT 1;

  IF v_request.id IS NULL THEN
    RETURN QUERY SELECT false, 'request not found', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_request.account_id <> v_account OR v_request.requested_by_uid <> v_uid THEN
    RETURN QUERY SELECT false, 'forbidden', v_account, v_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF v_request.status IN ('submitted', 'approved') THEN
    RETURN QUERY SELECT false, 'request already submitted', v_account, v_request.employee_user_uid, v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  UPDATE public.employee_seat_requests
     SET status = 'submitted',
         payment_method_id = p_payment_method_id,
         receipt_file_id = v_receipt,
         updated_at = now()
   WHERE id = p_request_id;

  RETURN QUERY SELECT true, NULL::text, v_account, v_request.employee_user_uid, v_uid, 'employee', NULL::boolean, true;
END;
$$;
REVOKE ALL ON FUNCTION public.owner_submit_employee_seat_payment(json, uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_submit_employee_seat_payment(json, uuid, uuid, text) TO PUBLIC;

COMMIT;
