BEGIN;

-- Enforce paid-plan gating for non-owner roles with no role escalation.
CREATE OR REPLACE FUNCTION public.fn_is_account_member(p_account uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = p_account
      AND au.user_uid::text = public.request_uid_text()::text
      AND coalesce(au.disabled, false) = false
      AND (
        lower(coalesce(au.role, '')) IN ('owner','superadmin')
        OR public.account_is_paid(p_account) = true
      )
  );
$$;
REVOKE ALL ON FUNCTION public.fn_is_account_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_account_member(uuid) TO PUBLIC;

-- Superadmin: enforce paid plan + seat limit (5) or approved seat request for extra.
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
  staff_count integer := 0;
  has_approved_seat boolean := false;
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

  SELECT count(*)
    INTO staff_count
    FROM public.account_users au
   WHERE au.account_id = p_account
     AND lower(coalesce(au.role, '')) IN ('employee','admin')
     AND coalesce(au.disabled, false) = false;

  emp_uid := public.admin_resolve_or_create_auth_user(
    normalized_email,
    normalized_password,
    normalized_role
  );

  IF staff_count >= 5 THEN
    SELECT EXISTS (
      SELECT 1
        FROM public.employee_seat_requests r
       WHERE r.account_id = p_account
         AND r.employee_user_uid = emp_uid
         AND r.status = 'approved'
         AND r.seat_kind = 'extra'
    ) INTO has_approved_seat;

    IF NOT COALESCE(has_approved_seat, false) THEN
      RETURN QUERY SELECT false, 'seat_payment_required', p_account, emp_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
      RETURN;
    END IF;
  END IF;

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

-- Owner: extra seat request should cost 50 USD.
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
    50
  );

  RETURN QUERY SELECT true, NULL::text, v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, true;
END;
$$;
REVOKE ALL ON FUNCTION public.owner_request_extra_employee(json, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_request_extra_employee(json, text, text) TO PUBLIC;

-- Owner: create employee within plan limit, prefer current account context.
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

-- Enforce paid plan + seat limits when attaching employees/admins.
CREATE OR REPLACE FUNCTION public.admin_attach_employee(
  p_account uuid,
  p_user_uid uuid,
  p_role text DEFAULT 'employee'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  exists_row boolean;
  caller_can_manage boolean;
  normalized_role text := lower(coalesce(p_role, 'employee'));
  is_super boolean := public.fn_is_super_admin();
  active_exists boolean := false;
  staff_count integer := 0;
  approved_extra boolean := false;
BEGIN
  IF p_account IS NULL OR p_user_uid IS NULL THEN
    RAISE EXCEPTION 'account_id and user_uid are required';
  END IF;

  IF is_super = false THEN
    SELECT EXISTS (
             SELECT 1
               FROM public.account_users au
              WHERE au.account_id = p_account
                AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
                AND COALESCE(au.disabled, false) = false
                AND lower(COALESCE(au.role, '')) = 'owner'
           )
      INTO caller_can_manage;

    IF NOT COALESCE(caller_can_manage, false) THEN
      RAISE EXCEPTION 'insufficient privileges to manage employees for this account'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF normalized_role IN ('employee', 'admin') THEN
    IF public.account_is_paid(p_account) IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'plan is free' USING ERRCODE = '42501';
    END IF;

    SELECT EXISTS (
      SELECT 1
        FROM public.account_users au
       WHERE au.account_id = p_account
         AND au.user_uid = p_user_uid
         AND lower(coalesce(au.role, '')) IN ('employee','admin')
         AND coalesce(au.disabled, false) = false
    ) INTO active_exists;

    SELECT count(*)
      INTO staff_count
      FROM public.account_users au
     WHERE au.account_id = p_account
       AND lower(coalesce(au.role, '')) IN ('employee','admin')
       AND coalesce(au.disabled, false) = false;

    IF staff_count >= 5 AND NOT COALESCE(active_exists, false) THEN
      SELECT EXISTS (
        SELECT 1
          FROM public.employee_seat_requests r
         WHERE r.account_id = p_account
           AND r.employee_user_uid = p_user_uid
           AND r.status = 'approved'
           AND r.seat_kind = 'extra'
      ) INTO approved_extra;

      IF NOT COALESCE(approved_extra, false) THEN
        RAISE EXCEPTION 'seat_payment_required' USING ERRCODE = '42501';
      END IF;
    END IF;
  END IF;

  SELECT true INTO exists_row
  FROM public.account_users
  WHERE account_id = p_account
    AND user_uid = p_user_uid
  LIMIT 1;

  IF NOT COALESCE(exists_row, false) THEN
    INSERT INTO public.account_users(account_id, user_uid, role, disabled)
    VALUES (p_account, p_user_uid, COALESCE(p_role, 'employee'), false);
  ELSE
    UPDATE public.account_users
       SET disabled = false,
           role = COALESCE(p_role, role),
           updated_at = now()
     WHERE account_id = p_account
       AND user_uid = p_user_uid;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'profiles'
  ) THEN
    INSERT INTO public.profiles(id, account_id, role, created_at)
    VALUES (p_user_uid, p_account, COALESCE(p_role, 'employee'), now())
    ON CONFLICT (id) DO UPDATE
        SET account_id = EXCLUDED.account_id,
            role = EXCLUDED.role;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_attach_employee(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_attach_employee(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO public;

-- Owner/admin helpers: resolve caller using request_uid_text for consistency.
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

-- Prevent disabling/deleting owners/admins (unless superadmin) and protect last owner.
CREATE OR REPLACE FUNCTION public.set_employee_disabled(
  p_account uuid,
  p_user_uid uuid,
  p_disabled boolean
) RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  caller_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  can_manage boolean;
  is_super_admin boolean := public.fn_is_super_admin();
  target_role text;
  owners_count integer := 0;
BEGIN
  SELECT EXISTS (
    SELECT 1
      FROM public.account_users
     WHERE account_id = p_account
       AND user_uid = caller_uid
       AND lower(coalesce(role,'')) IN ('owner','admin','superadmin')
       AND coalesce(disabled,false) = false
  ) INTO can_manage;

  IF NOT (can_manage OR is_super_admin) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT lower(coalesce(role, ''))
    INTO target_role
    FROM public.account_users
   WHERE account_id = p_account
     AND user_uid = p_user_uid
   LIMIT 1;

  IF target_role IN ('owner','admin') AND NOT is_super_admin THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF target_role = 'owner' AND coalesce(p_disabled, false) = true THEN
    SELECT count(*)
      INTO owners_count
      FROM public.account_users au
     WHERE au.account_id = p_account
       AND lower(coalesce(au.role,'')) = 'owner'
       AND coalesce(au.disabled,false) = false;

    IF owners_count <= 1 THEN
      RAISE EXCEPTION 'cannot_disable_last_owner' USING errcode = '23514';
    END IF;
  END IF;

  UPDATE public.account_users
     SET disabled = coalesce(p_disabled, false)
   WHERE account_id = p_account
     AND user_uid = p_user_uid;

  UPDATE public.profiles
     SET role = coalesce(target_role, role),
         account_id = coalesce(account_id, p_account),
         disabled = coalesce(p_disabled, false)
   WHERE id = p_user_uid;

  RETURN QUERY SELECT true, NULL::text, p_account, p_user_uid, NULL::uuid, target_role, NULL::boolean, coalesce(p_disabled, false);
END;
$$;
REVOKE ALL ON FUNCTION public.set_employee_disabled(uuid, uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.set_employee_disabled(uuid, uuid, boolean) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.delete_employee(
  p_account uuid,
  p_user_uid uuid
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  caller_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  can_manage boolean;
  is_super_admin boolean := public.fn_is_super_admin();
  target_role text;
  owners_count integer := 0;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.account_users
    WHERE account_id = p_account
      AND user_uid = caller_uid
      AND lower(coalesce(role,'')) in ('owner','admin','superadmin')
      AND coalesce(disabled,false) = false
  ) INTO can_manage;

  IF NOT (can_manage OR is_super_admin) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT lower(coalesce(role, ''))
    INTO target_role
    FROM public.account_users
   WHERE account_id = p_account
     AND user_uid = p_user_uid
   LIMIT 1;

  IF target_role IN ('owner','admin') AND NOT is_super_admin THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF target_role = 'owner' THEN
    SELECT count(*)
      INTO owners_count
      FROM public.account_users au
     WHERE au.account_id = p_account
       AND lower(coalesce(au.role,'')) = 'owner'
       AND coalesce(au.disabled,false) = false;

    IF owners_count <= 1 THEN
      RAISE EXCEPTION 'cannot_delete_last_owner' USING errcode = '23514';
    END IF;
  END IF;

  DELETE FROM public.account_users
   WHERE account_id = p_account
     AND user_uid = p_user_uid;

  UPDATE public.profiles
     SET role = 'removed'
   WHERE id = p_user_uid
     AND coalesce(account_id, p_account) = p_account;

  RETURN QUERY SELECT true, NULL::text, p_account, p_user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.delete_employee(uuid, uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.delete_employee(uuid, uuid) TO public;

-- Superadmin: block approving extra seats when account is free.
CREATE OR REPLACE FUNCTION public.superadmin_review_employee_seat_request(
  p_request_id uuid,
  p_approve boolean,
  p_note text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_request record;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT *
    INTO v_request
    FROM public.employee_seat_requests r
   WHERE r.id = p_request_id
   LIMIT 1;

  IF v_request.id IS NULL THEN
    RETURN QUERY SELECT false, 'request not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.account_is_paid(v_request.account_id) IS DISTINCT FROM true THEN
    RETURN QUERY SELECT false, 'plan is free', v_request.account_id, v_request.employee_user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_approve IS TRUE THEN
    UPDATE public.employee_seat_requests
       SET status = 'approved',
           admin_note = NULLIF(trim(coalesce(p_note, '')), ''),
           updated_at = now()
     WHERE id = p_request_id;

    UPDATE public.account_users
       SET disabled = false,
           updated_at = now()
     WHERE account_id = v_request.account_id
       AND user_uid = v_request.employee_user_uid;

    UPDATE public.profiles
       SET disabled = false,
           updated_at = now()
     WHERE id = v_request.employee_user_uid;

    PERFORM public.auth_set_user_claims(
      v_request.employee_user_uid,
      'employee',
      v_request.account_id
    );

    RETURN QUERY SELECT true, NULL::text, v_request.account_id, v_request.employee_user_uid, NULL::uuid, 'employee', NULL::boolean, false;
  ELSE
    UPDATE public.employee_seat_requests
       SET status = 'rejected',
           admin_note = NULLIF(trim(coalesce(p_note, '')), ''),
           updated_at = now()
     WHERE id = p_request_id;

    RETURN QUERY SELECT true, NULL::text, v_request.account_id, v_request.employee_user_uid, NULL::uuid, 'employee', NULL::boolean, true;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.superadmin_review_employee_seat_request(uuid, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.superadmin_review_employee_seat_request(uuid, boolean, text) TO PUBLIC;

COMMIT;
