BEGIN;

-- 1) account_users: add chat_code (unique 7-digit starting 555)
ALTER TABLE public.account_users
  ADD COLUMN IF NOT EXISTS chat_code text;

ALTER TABLE public.account_users
  DROP CONSTRAINT IF EXISTS account_users_chat_code_format;
ALTER TABLE public.account_users
  ADD CONSTRAINT account_users_chat_code_format
  CHECK (chat_code IS NULL OR chat_code ~ '^555[0-9]{4}$');

CREATE UNIQUE INDEX IF NOT EXISTS account_users_chat_code_key
  ON public.account_users(chat_code)
  WHERE chat_code IS NOT NULL;

-- 2) Return-type view: add chat_code to v_my_profile + v_list_employees_with_email
CREATE OR REPLACE VIEW public.v_my_profile AS
SELECT
  NULL::uuid AS id,
  NULL::text AS email,
  NULL::text AS role,
  NULL::uuid AS account_id,
  NULL::text AS display_name,
  ARRAY[]::uuid[] AS account_ids,
  NULL::text AS chat_code
WHERE false;

CREATE OR REPLACE VIEW public.v_list_employees_with_email AS
SELECT
  NULL::uuid AS user_uid,
  NULL::text AS email,
  NULL::text AS role,
  NULL::boolean AS disabled,
  NULL::timestamptz AS created_at,
  NULL::uuid AS employee_id,
  NULL::uuid AS doctor_id,
  NULL::text AS chat_code
WHERE false;

CREATE OR REPLACE VIEW public.v_admin_dashboard_account_members AS
SELECT
  au.account_id,
  a.name AS account_name,
  au.user_uid,
  au.email,
  au.role,
  au.disabled,
  au.created_at,
  au.chat_code
FROM public.account_users au
JOIN public.accounts a ON a.id = au.account_id;

CREATE OR REPLACE VIEW public.v_chat_user_lookup AS
SELECT
  NULL::uuid AS user_uid,
  NULL::text AS email,
  NULL::uuid AS account_id,
  NULL::text AS role,
  NULL::text AS chat_code
WHERE false;

CREATE OR REPLACE FUNCTION public.chat_resolve_user_for_dm(
  hasura_session json,
  p_identifier text
)
RETURNS SETOF public.v_chat_user_lookup
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(hasura_session->>'x-hasura-user-id','')::uuid;
  v_account uuid;
  v_role text;
  v_ident text := lower(coalesce(trim(p_identifier), ''));
  v_is_super boolean := public.fn_is_super_admin();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING errcode = '42501';
  END IF;
  IF v_ident = '' THEN
    RAISE EXCEPTION 'identifier required' USING errcode = '22023';
  END IF;

  SELECT au.account_id, au.role
    INTO v_account, v_role
  FROM public.account_users au
  WHERE au.user_uid = v_uid
    AND coalesce(au.disabled,false) = false
  ORDER BY au.created_at DESC
  LIMIT 1;

  IF NOT v_is_super AND lower(coalesce(v_role,'')) = 'employee' THEN
    IF v_account IS NULL THEN
      RETURN;
    END IF;
    IF v_ident ~ '^555[0-9]{4}$' THEN
      RETURN QUERY
      SELECT au.user_uid,
             coalesce(u.email, au.email) AS email,
             au.account_id,
             au.role,
             au.chat_code
      FROM public.account_users au
      LEFT JOIN auth.users u ON u.id = au.user_uid
      WHERE au.account_id = v_account
        AND au.chat_code = v_ident
      ORDER BY au.created_at DESC
      LIMIT 1;
      RETURN;
    END IF;

    IF v_ident ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
      RETURN QUERY
      SELECT au.user_uid,
             coalesce(u.email, au.email) AS email,
             au.account_id,
             au.role,
             au.chat_code
      FROM public.account_users au
      LEFT JOIN auth.users u ON u.id = au.user_uid
      WHERE au.account_id = v_account
        AND lower(coalesce(au.email,'')) = v_ident
      ORDER BY au.created_at DESC
      LIMIT 1;
      RETURN;
    END IF;

    -- Don't allow free-form searches for employees
    RETURN;
  END IF;

  RETURN QUERY
  SELECT au.user_uid,
         coalesce(u.email, au.email) AS email,
         au.account_id,
         au.role,
         au.chat_code
  FROM public.account_users au
  LEFT JOIN auth.users u ON u.id = au.user_uid
  WHERE lower(coalesce(au.email,'')) = v_ident
     OR au.chat_code = v_ident
  ORDER BY au.created_at DESC
  LIMIT 1;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_resolve_user_for_dm(json, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_resolve_user_for_dm(json, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_dashboard_account_members(
  hasura_session json,
  p_account uuid DEFAULT NULL,
  p_only_active boolean DEFAULT true
)
RETURNS SETOF public.v_admin_dashboard_account_members
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.v_admin_dashboard_account_members
  WHERE (p_account IS NULL OR account_id = p_account)
    AND (NOT p_only_active OR coalesce(disabled,false) = false)
  ORDER BY created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_dashboard_account_members(json, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_account_members(json, uuid, boolean) TO PUBLIC;
-- 3) Code generator + helpers
CREATE OR REPLACE FUNCTION public.generate_chat_code(p_owner_code text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text;
  v_owner_prefix text;
  v_try int := 0;
BEGIN
  IF p_owner_code IS NOT NULL AND p_owner_code ~ '^555[0-9]{4}$' THEN
    v_owner_prefix := substr(p_owner_code, 1, 5); -- 555 + أول رقمين من كود المالك
  END IF;

  LOOP
    v_try := v_try + 1;
    IF v_owner_prefix IS NOT NULL THEN
      v_code := v_owner_prefix || lpad((floor(random() * 100))::int::text, 2, '0');
    ELSE
      v_code := '555' || lpad((floor(random() * 10000))::int::text, 4, '0');
    END IF;

    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.account_users au WHERE au.chat_code = v_code
    );

    IF v_try >= 2000 THEN
      RAISE EXCEPTION 'chat_code_exhausted';
    END IF;
  END LOOP;

  RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION public.ensure_account_owner_chat_code(p_account uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner_uid uuid;
  v_code text;
BEGIN
  IF p_account IS NULL THEN
    RETURN NULL;
  END IF;

  -- لا تُنشئ كودًا إلا للحسابات المدفوعة
  IF public.account_is_paid(p_account) IS DISTINCT FROM true THEN
    RETURN NULL;
  END IF;

  SELECT au.user_uid, au.chat_code
    INTO v_owner_uid, v_code
  FROM public.account_users au
  WHERE au.account_id = p_account
    AND lower(coalesce(au.role, '')) = 'owner'
  ORDER BY au.created_at DESC
  LIMIT 1;

  IF v_owner_uid IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_code IS NULL OR btrim(v_code) = '' THEN
    v_code := public.generate_chat_code(NULL);
    UPDATE public.account_users
       SET chat_code = v_code,
           updated_at = now()
     WHERE account_id = p_account
       AND user_uid = v_owner_uid;
  END IF;

  RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION public.ensure_account_user_chat_code(
  p_account uuid,
  p_user uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_code text;
  v_owner_code text;
BEGIN
  IF p_account IS NULL OR p_user IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT au.role, au.chat_code
    INTO v_role, v_code
  FROM public.account_users au
  WHERE au.account_id = p_account
    AND au.user_uid = p_user
  LIMIT 1;

  IF v_code IS NOT NULL AND btrim(v_code) <> '' THEN
    RETURN v_code;
  END IF;

  IF lower(coalesce(v_role, '')) = 'owner' THEN
    RETURN public.ensure_account_owner_chat_code(p_account);
  END IF;

  v_owner_code := public.ensure_account_owner_chat_code(p_account);
  IF v_owner_code IS NULL OR btrim(v_owner_code) = '' THEN
    -- كحل احتياطي: توليد كود عام إن لم يتوفر كود مالك
    v_code := public.generate_chat_code(NULL);
  ELSE
    v_code := public.generate_chat_code(v_owner_code);
  END IF;

  UPDATE public.account_users
     SET chat_code = v_code,
         updated_at = now()
   WHERE account_id = p_account
     AND user_uid = p_user;

  RETURN v_code;
END;
$$;

-- 4) تحديث my_profile لإرجاع chat_code
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
  profile AS (
    SELECT p.id,
           p.role AS profile_role,
           p.account_id AS profile_account_id,
           p.display_name
    FROM public.profiles p
    JOIN me ON p.id = me.id
    LIMIT 1
  ),
  current_acc AS (
    SELECT uca.account_id
    FROM public.user_current_account uca
    JOIN me ON uca.user_uid = me.id
    LIMIT 1
  ),
  membership_latest AS (
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
      ) AS account_id,
      (SELECT au2.chat_code
         FROM public.account_users au2
        WHERE au2.user_uid = au.user_uid
          AND coalesce(au2.disabled,false) = false
        ORDER BY au2.created_at DESC
        LIMIT 1
      ) AS chat_code
    FROM public.account_users au
    WHERE au.user_uid = (SELECT id FROM me)
    LIMIT 1
  ),
  membership_current AS (
    SELECT au.role, au.account_id, au.chat_code
    FROM public.account_users au
    WHERE au.user_uid = (SELECT id FROM me)
      AND coalesce(au.disabled,false) = false
      AND au.account_id = (SELECT account_id FROM current_acc)
    LIMIT 1
  )
  SELECT
    me.id,
    me.email,
    CASE
      WHEN (SELECT is_super_admin FROM public.fn_is_super_admin_gql(hasura_session) LIMIT 1)
        THEN 'superadmin'
      ELSE coalesce(
        (SELECT role FROM membership_current),
        membership_latest.role,
        profile.profile_role,
        'employee'
      )
    END AS role,
    coalesce(
      (SELECT account_id FROM membership_current),
      membership_latest.account_id,
      profile.profile_account_id
    ) AS account_id,
    profile.display_name,
    coalesce(
      membership_latest.account_ids,
      CASE
        WHEN profile.profile_account_id IS NOT NULL
          THEN ARRAY[profile.profile_account_id]::uuid[]
        ELSE ARRAY[]::uuid[]
      END
    ) AS account_ids,
    coalesce(
      (SELECT chat_code FROM membership_current),
      membership_latest.chat_code
    ) AS chat_code
  FROM me
  LEFT JOIN membership_latest ON membership_latest.user_uid = me.id
  LEFT JOIN profile ON profile.id = me.id;
$$;

-- 5) list_employees_with_email: include chat_code
CREATE OR REPLACE FUNCTION public.list_employees_with_email(hasura_session json, p_account uuid)
RETURNS SETOF public.v_list_employees_with_email
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
SET row_security TO 'off'
AS $$
DECLARE
  session_json jsonb := '{}'::jsonb;
  raw_hasura_user text := current_setting('hasura.user', true);
  raw_claims text := current_setting('request.jwt.claims', true);
  hasura_user jsonb := '{}'::jsonb;
  claims jsonb := '{}'::jsonb;
  caller_uid_text text;
  caller_uid uuid;
  can_manage boolean;
  is_super boolean := public.fn_is_super_admin();
BEGIN
  BEGIN
    IF hasura_session IS NOT NULL THEN
      session_json := hasura_session::jsonb;
    END IF;
  EXCEPTION WHEN others THEN
    session_json := '{}'::jsonb;
  END;

  IF raw_hasura_user IS NOT NULL AND raw_hasura_user <> '' THEN
    BEGIN
      hasura_user := raw_hasura_user::jsonb;
    EXCEPTION WHEN others THEN
      hasura_user := '{}'::jsonb;
    END;
  END IF;

  IF raw_claims IS NOT NULL AND raw_claims <> '' THEN
    BEGIN
      claims := raw_claims::jsonb;
    EXCEPTION WHEN others THEN
      claims := '{}'::jsonb;
    END;
  END IF;

  caller_uid_text := NULLIF(
    COALESCE(
      session_json ->> 'x-hasura-user-id',
      hasura_user ->> 'x-hasura-user-id',
      current_setting('request.jwt.claim.x-hasura-user-id', true),
      current_setting('request.jwt.claim.sub', true),
      claims -> 'https://hasura.io/jwt/claims' ->> 'x-hasura-user-id',
      claims ->> 'x-hasura-user-id',
      claims ->> 'sub'
    ),
    ''
  );

  BEGIN
    caller_uid := NULLIF(caller_uid_text, '')::uuid;
  EXCEPTION WHEN others THEN
    caller_uid := NULL;
  END;

  IF caller_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.account_users
    WHERE account_id = p_account
      AND user_uid = caller_uid
      AND lower(coalesce(role, '')) IN ('owner','admin')
      AND coalesce(disabled, false) = false
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
    d.id AS doctor_id,
    au.chat_code
  FROM public.account_users au
  LEFT JOIN auth.users u ON u.id = au.user_uid
  LEFT JOIN public.employees e ON e.account_id = au.account_id AND e.user_uid = au.user_uid
  LEFT JOIN public.doctors d ON d.account_id = au.account_id AND d.user_uid = au.user_uid
  WHERE au.account_id = p_account
  ORDER BY au.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_employees_with_email(json, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_employees_with_email(json, uuid) TO PUBLIC;

-- 6) admin_approve_subscription_request: assign owner chat code after approval
CREATE OR REPLACE FUNCTION public.admin_approve_subscription_request(
  p_request uuid,
  p_note text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  r record;
  plan record;
  v_start timestamptz := now();
  v_end timestamptz := NULL;
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT *
  INTO r
  FROM public.subscription_requests
  WHERE id = p_request
  LIMIT 1;

  IF r.id IS NULL THEN
    RETURN QUERY SELECT false, 'request not found', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF r.status <> 'pending' THEN
    RETURN QUERY SELECT false, 'request already processed', r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT * INTO plan
  FROM public.subscription_plans
  WHERE code = r.plan_code
  LIMIT 1;

  IF plan.code IS NULL THEN
    RETURN QUERY SELECT false, 'plan not found', r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF coalesce(plan.duration_months, 0) > 0 THEN
    v_end := v_start + (plan.duration_months::text || ' months')::interval;
  END IF;

  UPDATE public.subscription_requests
     SET status = 'approved',
         note = p_note,
         reviewed_by = v_uid,
         reviewed_at = now()
   WHERE id = r.id;

  UPDATE public.account_subscriptions
     SET status = 'expired',
         updated_at = now()
   WHERE account_id = r.account_id
     AND status = 'active';

  INSERT INTO public.account_subscriptions(
    account_id, plan_code, status, start_at, end_at, approved_by, approved_at, request_id
  )
  VALUES (
    r.account_id, plan.code, 'active', v_start, v_end, v_uid, now(), r.id
  );

  IF coalesce(r.amount, 0) > 0 THEN
    INSERT INTO public.subscription_payments(
      account_id, request_id, payment_method_id, plan_code, amount, created_by
    )
    VALUES (r.account_id, r.id, r.payment_method_id, r.plan_code, r.amount, v_uid);
  END IF;

  PERFORM public.apply_plan_permissions(r.account_id, r.plan_code);

  -- إنشاء كود المالك فور الموافقة على الخطة
  PERFORM public.ensure_account_owner_chat_code(r.account_id);

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    r.account_id, v_uid, 'account_subscriptions', 'plan.approve', r.id::text,
    jsonb_build_object('plan', r.plan_code, 'request_id', r.id, 'note', p_note)
  );

  RETURN QUERY SELECT true, NULL::text, r.account_id, r.user_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_approve_subscription_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_approve_subscription_request(uuid, text) TO public;

-- 7) admin_create_employee_full: ensure chat_code for new employees
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

  PERFORM public.auth_set_user_claims(emp_uid, normalized_role, p_account);

  -- إنشاء كود الموظف وفق كود المالك (إذا كان مدفوعًا)
  PERFORM public.ensure_account_user_chat_code(p_account, emp_uid);

  RETURN QUERY SELECT true, NULL::text, p_account, emp_uid, NULL::uuid, normalized_role, NULL::boolean, NULL::boolean;
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT false, SQLERRM, p_account, emp_uid, NULL::uuid, normalized_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_create_employee_full(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO public;

-- 7.1) owner_create_employee_within_limit: ensure chat_code for owner-created employees
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

  -- إنشاء كود الموظف وفق كود المالك (إذا كان مدفوعًا)
  PERFORM public.ensure_account_user_chat_code(v_account, v_emp_uid);

  RETURN QUERY SELECT true, NULL::text, v_account, v_emp_uid, v_uid, 'employee', NULL::boolean, false;
END;
$$;
REVOKE ALL ON FUNCTION public.owner_create_employee_within_limit(json, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_create_employee_within_limit(json, text, text) TO PUBLIC;
-- 8) chat_start_dm: set nickname = chat_code when available
CREATE OR REPLACE FUNCTION public.chat_start_dm(p_other_uid uuid)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_me uuid;
  v_other uuid := p_other_uid;
  v_conv uuid;
  v_me_acc uuid;
  v_other_acc uuid;
  v_me_role text;
  v_other_role text;
  v_me_disabled boolean := false;
  v_other_disabled boolean := false;
  v_account_id uuid;
  v_other_is_super boolean := false;
  v_me_chat_role text := 'member';
  v_other_chat_role text := 'member';
  v_me_code text;
  v_other_code text;
BEGIN
  v_me := nullif(public.request_uid_text(), '')::uuid;
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF v_other IS NULL THEN
    RAISE EXCEPTION 'missing target';
  END IF;

  IF v_other = v_me THEN
    RAISE EXCEPTION 'cannot dm self';
  END IF;

  PERFORM 1 FROM auth.users u WHERE u.id = v_other;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'target not found';
  END IF;

  SELECT account_id, role, coalesce(disabled,false)
    INTO v_me_acc, v_me_role, v_me_disabled
  FROM public.account_users
  WHERE user_uid = v_me
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT account_id, role, coalesce(disabled,false)
    INTO v_other_acc, v_other_role, v_other_disabled
  FROM public.account_users
  WHERE user_uid = v_other
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_me_disabled THEN
    RAISE EXCEPTION 'sender disabled';
  END IF;

  IF v_other_disabled THEN
    RAISE EXCEPTION 'target disabled';
  END IF;

  IF v_me_role IS NULL THEN
    v_me_role := 'employee';
  END IF;

  IF v_other_role IS NULL THEN
    v_other_role := 'employee';
  END IF;

  IF v_me_acc IS NOT NULL AND v_other_acc IS NOT NULL AND v_me_acc = v_other_acc THEN
    v_account_id := v_me_acc;
  ELSE
    v_account_id := NULL;
  END IF;

  IF to_regproc('public.fn_is_super_admin_email(text)') IS NOT NULL THEN
    SELECT COALESCE(public.fn_is_super_admin_email(u.email), false)
      INTO v_other_is_super
    FROM auth.users u
    WHERE u.id = v_other;
  ELSE
    v_other_is_super := false;
  END IF;

  -- Enforce DM rules:
  -- - Employee can DM only within the same account (never cross-account).
  -- - Owner/Admin can DM across accounts.
  -- - Owner can DM superadmin; employee cannot.
  IF lower(coalesce(v_me_role, '')) = 'employee' THEN
    IF v_other_is_super THEN
      RAISE EXCEPTION 'superadmin dm forbidden';
    END IF;
    IF v_me_acc IS NULL OR v_other_acc IS NULL OR v_me_acc <> v_other_acc THEN
      RAISE EXCEPTION 'cross-account dm forbidden';
    END IF;
  END IF;

  IF v_other_is_super THEN
    IF public.fn_is_super_admin() THEN
      NULL;
    ELSE
      IF lower(coalesce(v_me_role, '')) NOT IN ('owner','admin') THEN
        RAISE EXCEPTION 'superadmin dm forbidden';
      END IF;
    END IF;
  END IF;

  IF lower(coalesce(v_me_role, '')) IN ('owner','admin') THEN
    v_me_chat_role := lower(v_me_role);
  END IF;
  IF v_other_is_super THEN
    v_other_chat_role := 'admin';
  ELSIF lower(coalesce(v_other_role, '')) IN ('owner','admin') THEN
    v_other_chat_role := lower(v_other_role);
  END IF;

  SELECT c.id INTO v_conv
  FROM public.chat_conversations c
  JOIN public.chat_participants p1
    ON p1.conversation_id = c.id AND p1.user_uid = v_me
  JOIN public.chat_participants p2
    ON p2.conversation_id = c.id AND p2.user_uid = v_other
  WHERE c.is_group = false
  ORDER BY c.created_at DESC
  LIMIT 1;

  IF v_conv IS NULL THEN
    v_conv := gen_random_uuid();
    INSERT INTO public.chat_conversations(
      id, is_group, title, account_id, created_by, created_at, updated_at
    ) VALUES (
      v_conv, false, NULL, v_account_id, v_me, now(), now()
    );
  END IF;

  SELECT au.chat_code
    INTO v_me_code
  FROM public.account_users au
  WHERE au.user_uid = v_me
    AND (v_me_acc IS NULL OR au.account_id = v_me_acc)
  ORDER BY au.created_at DESC
  LIMIT 1;

  SELECT au.chat_code
    INTO v_other_code
  FROM public.account_users au
  WHERE au.user_uid = v_other
    AND (v_other_acc IS NULL OR au.account_id = v_other_acc)
  ORDER BY au.created_at DESC
  LIMIT 1;

  INSERT INTO public.chat_participants(
    conversation_id, user_uid, email, nickname, joined_at, role
  )
  VALUES
    (
      v_conv,
      v_me,
      (SELECT email FROM auth.users WHERE id = v_me),
      v_me_code,
      now(),
      v_me_chat_role
    ),
    (
      v_conv,
      v_other,
      (SELECT email FROM auth.users WHERE id = v_other),
      v_other_code,
      now(),
      v_other_chat_role
    )
  ON CONFLICT (conversation_id, user_uid) DO UPDATE
    SET email = EXCLUDED.email,
        nickname = COALESCE(public.chat_participants.nickname, EXCLUDED.nickname),
        joined_at = EXCLUDED.joined_at,
        role = COALESCE(public.chat_participants.role, EXCLUDED.role);

  RETURN QUERY SELECT v_conv::uuid AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.chat_start_dm(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_start_dm(uuid) TO PUBLIC;

-- 9) backfill codes + participant nicknames for existing paid accounts
DO $$
DECLARE
  r record;
  v_owner_code text;
BEGIN
  FOR r IN SELECT DISTINCT account_id FROM public.account_users LOOP
    v_owner_code := public.ensure_account_owner_chat_code(r.account_id);
    IF v_owner_code IS NULL OR btrim(v_owner_code) = '' THEN
      CONTINUE;
    END IF;

    UPDATE public.account_users
       SET chat_code = public.generate_chat_code(v_owner_code),
           updated_at = now()
     WHERE account_id = r.account_id
       AND (chat_code IS NULL OR btrim(chat_code) = '')
       AND lower(coalesce(role,'')) <> 'owner';
  END LOOP;

  UPDATE public.chat_participants p
     SET nickname = au.chat_code
    FROM public.account_users au
   WHERE au.account_id = p.account_id
     AND au.user_uid = p.user_uid
     AND (p.nickname IS NULL OR btrim(p.nickname) = '')
     AND au.chat_code IS NOT NULL;
END;
$$;

COMMIT;
