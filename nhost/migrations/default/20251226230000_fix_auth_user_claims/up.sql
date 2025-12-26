BEGIN;

-- Helper: update auth.users claims/metadata only for existing columns.
CREATE OR REPLACE FUNCTION public.auth_set_user_claims(
  p_uid uuid,
  p_role text,
  p_account uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_role text := lower(coalesce(nullif(p_role, ''), 'employee'));
  v_account text := nullif(p_account::text, '');
  v_meta jsonb := jsonb_strip_nulls(
    jsonb_build_object('role', v_role, 'account_id', v_account)
  );
BEGIN
  IF p_uid IS NULL THEN
    RAISE EXCEPTION 'uid is required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'default_role'
  ) THEN
    EXECUTE 'UPDATE auth.users SET default_role = $2 WHERE id = $1'
      USING p_uid, v_role;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'roles'
  ) THEN
    EXECUTE 'UPDATE auth.users SET roles = (SELECT ARRAY(SELECT DISTINCT unnest(COALESCE(roles, ARRAY[]::text[])) || $2)) WHERE id = $1'
      USING p_uid, v_role;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET metadata = COALESCE(metadata, ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'app_metadata'
  ) THEN
    EXECUTE 'UPDATE auth.users SET app_metadata = COALESCE(app_metadata, ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'raw_app_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_app_meta_data = COALESCE(raw_app_meta_data, ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'raw_user_meta_data'
  ) THEN
    EXECUTE 'UPDATE auth.users SET raw_user_meta_data = COALESCE(raw_user_meta_data, ''{}''::jsonb) || $2 WHERE id = $1'
      USING p_uid, v_meta;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO PUBLIC;

-- Admin helper: resolve an auth user and apply role metadata safely.
CREATE OR REPLACE FUNCTION public.admin_resolve_or_create_auth_user(
  p_email text,
  p_password text DEFAULT NULL,
  p_role text DEFAULT 'employee'
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  normalized_email text := lower(coalesce(trim(p_email), ''));
  normalized_role text := coalesce(nullif(trim(p_role), ''), 'employee');
  normalized_password text := nullif(coalesce(trim(p_password), ''), '');
  target_uid uuid;
BEGIN
  IF normalized_email = '' THEN
    RAISE EXCEPTION 'email is required';
  END IF;

  SELECT id
    INTO target_uid
    FROM auth.users
   WHERE lower(email) = normalized_email
   ORDER BY created_at DESC
   LIMIT 1;

  IF target_uid IS NULL THEN
    RAISE EXCEPTION 'auth user not found for %; create it via edge function first',
      normalized_email
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'auth'
      AND table_name = 'users'
      AND column_name = 'email_confirmed_at'
  ) THEN
    EXECUTE 'UPDATE auth.users SET email_confirmed_at = COALESCE(email_confirmed_at, now()) WHERE id = $1'
      USING target_uid;
  END IF;

  PERFORM public.auth_set_user_claims(target_uid, normalized_role, NULL::uuid);

  RETURN target_uid;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_resolve_or_create_auth_user(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_resolve_or_create_auth_user(text, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_resolve_or_create_auth_user(text, text, text) TO public;

-- Admin RPC: create owner (safe auth metadata update).
CREATE OR REPLACE FUNCTION public.admin_create_owner_full(
  p_clinic_name text,
  p_owner_email text,
  p_owner_password text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  normalized_clinic text := coalesce(nullif(trim(p_clinic_name), ''), '');
  normalized_email text := lower(coalesce(trim(p_owner_email), ''));
  normalized_role text := 'owner';
  normalized_password text := nullif(coalesce(trim(p_owner_password), ''), '');
  owner_uid uuid;
  acc_id uuid;
BEGIN
  IF normalized_clinic = '' OR normalized_email = '' THEN
    RETURN QUERY SELECT false, 'clinic_name and owner_email are required', NULL::uuid, NULL::uuid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  owner_uid := public.admin_resolve_or_create_auth_user(
    normalized_email,
    normalized_password,
    normalized_role
  );

  INSERT INTO public.accounts(name, frozen)
  VALUES (normalized_clinic, false)
  RETURNING id INTO acc_id;

  PERFORM public.admin_attach_employee(acc_id, owner_uid, normalized_role);

  UPDATE public.account_users
     SET email = normalized_email,
         role = normalized_role,
         disabled = false,
         updated_at = now()
   WHERE account_id = acc_id
     AND user_uid = owner_uid;

  UPDATE public.profiles
     SET account_id = acc_id,
         role = normalized_role,
         email = normalized_email,
         disabled = false,
         updated_at = now()
   WHERE id = owner_uid;

  PERFORM public.auth_set_user_claims(owner_uid, normalized_role, acc_id);

  RETURN QUERY SELECT true, NULL::text, acc_id, owner_uid, owner_uid, normalized_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_create_owner_full(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO public;

-- Admin RPC: create employee (safe auth metadata update).
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
  ) INTO account_exists;

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

  PERFORM public.auth_set_user_claims(emp_uid, normalized_role, p_account);

  RETURN QUERY SELECT true, NULL::text, p_account, emp_uid, NULL::uuid, normalized_role, NULL::boolean, NULL::boolean;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_create_employee_full(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO public;

-- Self signup: create owner account (safe auth metadata update).
CREATE OR REPLACE FUNCTION public.self_create_account(p_clinic_name text)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_name text := coalesce(nullif(trim(p_clinic_name), ''), '');
  v_account uuid;
  v_email text;
  exists_member boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'clinic_name is required';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.user_uid = v_uid
  ) INTO exists_member;

  IF exists_member THEN
    RAISE EXCEPTION 'already linked to an account' USING ERRCODE = '23505';
  END IF;

  SELECT lower(coalesce(email, ''))
    INTO v_email
    FROM auth.users
   WHERE id = v_uid
   ORDER BY created_at DESC
   LIMIT 1;

  INSERT INTO public.accounts(name, frozen)
  VALUES (v_name, false)
  RETURNING id INTO v_account;

  INSERT INTO public.account_users(account_id, user_uid, role, disabled, email)
  VALUES (v_account, v_uid, 'owner', false, nullif(v_email, ''));

  INSERT INTO public.profiles(id, account_id, role, email, disabled, created_at)
  VALUES (
    v_uid,
    v_account,
    'owner',
    nullif(v_email, ''),
    false,
    now()
  )
  ON CONFLICT (id) DO UPDATE
      SET account_id = EXCLUDED.account_id,
          role = EXCLUDED.role,
          email = COALESCE(EXCLUDED.email, public.profiles.email),
          disabled = false;

  PERFORM public.auth_set_user_claims(v_uid, 'owner', v_account);

  INSERT INTO public.account_feature_permissions(account_id, user_uid, allowed_features)
  VALUES (v_account, v_uid, public.plan_allowed_features('free'))
  ON CONFLICT (account_id, user_uid) DO NOTHING;

  INSERT INTO public.account_subscriptions(account_id, plan_code, status, start_at, end_at, approved_at)
  VALUES (v_account, 'free', 'active', now(), NULL, now());

  PERFORM public.apply_plan_permissions(v_account, 'free');

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    v_account, v_uid, 'accounts', 'account.bootstrap', v_account::text,
    jsonb_build_object('plan', 'free', 'owner', v_uid::text)
  );

  RETURN QUERY SELECT v_account AS id;
END;
$$;
REVOKE ALL ON FUNCTION public.self_create_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_create_account(text) TO public;

COMMIT;
