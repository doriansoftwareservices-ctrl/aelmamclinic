-- 20251201090000_super_admin_unification.sql
-- Unify super-admin handling between the Flutter client and Supabase by
-- introducing a reusable helper, eliminating hard-coded email checks, and
-- exposing an RPC that allows the tool/sync_super_admins.dart script to seed
-- `public.super_admins` from AppConstants.superAdminEmails.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_is_super_admin_email(p_email text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    CASE
      WHEN p_email IS NULL OR trim(p_email) = '' THEN FALSE
      ELSE EXISTS (
        SELECT 1
          FROM public.super_admins sa
         WHERE lower(sa.email) = lower(trim(p_email))
      )
    END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_email(text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin_email(text) TO public;

CREATE OR REPLACE FUNCTION public.fn_is_super_admin()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_role text := current_setting('request.jwt.claim.role', true);
  v_uid uuid := public.request_uid_text();
  v_email text := lower(coalesce(auth.email(), ''));
  v_lookup_email text;
BEGIN
  IF v_role = 'service_role' THEN
    RETURN true;
  END IF;

  IF v_uid IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
        FROM public.super_admins sa
       WHERE sa.user_uid = v_uid
    ) THEN
      RETURN true;
    END IF;
  END IF;

  IF v_email <> '' AND fn_is_super_admin_email(v_email) THEN
    RETURN true;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT lower(u.email)
      INTO v_lookup_email
      FROM auth.users u
     WHERE u.id = v_uid
     LIMIT 1;

    IF v_lookup_email IS NOT NULL AND fn_is_super_admin_email(v_lookup_email) THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_super_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_super_admin() TO public;

CREATE OR REPLACE FUNCTION public.admin_sync_super_admin_emails(p_emails text[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text;
  normalized text;
BEGIN
  IF p_emails IS NULL OR array_length(p_emails, 1) IS NULL THEN
    RETURN;
  END IF;

  FOREACH v_email IN ARRAY p_emails LOOP
    normalized := lower(coalesce(trim(v_email), ''));
    IF normalized = '' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.super_admins(email)
    VALUES (normalized)
    ON CONFLICT (email) DO NOTHING;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_sync_super_admin_emails(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_sync_super_admin_emails(text[]) TO public;

-- ───────── RPC & helper updates without hard-coded emails ─────────

CREATE OR REPLACE FUNCTION public.my_feature_permissions(p_account uuid)
RETURNS TABLE (
  account_id       uuid,
  allowed_features text[],
  can_create       boolean,
  can_update       boolean,
  can_delete       boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := public.request_uid_text();
  v_is_super boolean := coalesce(public.fn_is_super_admin(), false)
    OR lower(coalesce(current_setting('request.jwt.claims', true)::json ->> 'role', '')) = 'superadmin'
    OR public.fn_is_super_admin_email(current_setting('request.jwt.claims', true)::json ->> 'email');
  v_allowed text[];
  v_can_create boolean;
  v_can_update boolean;
  v_can_delete boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  IF p_account IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, array[]::text[], true, true, true;
  END IF;

  IF NOT v_is_super THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.account_users au
      WHERE au.account_id = p_account
        AND au.user_uid = v_uid
        AND COALESCE(au.disabled, false) = false
    ) THEN
      RAISE EXCEPTION 'forbidden' USING errcode = '42501';
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'account_feature_permissions'
  ) THEN
    RETURN QUERY SELECT p_account, array[]::text[], true, true, true;
  END IF;

  SELECT
    afp.allowed_features,
    afp.can_create,
    afp.can_update,
    afp.can_delete
  INTO v_allowed, v_can_create, v_can_update, v_can_delete
  FROM public.account_feature_permissions afp
  WHERE afp.account_id = p_account
    AND (afp.user_uid = v_uid OR afp.user_uid IS NULL)
  ORDER BY CASE WHEN afp.user_uid = v_uid THEN 0 ELSE 1 END
  LIMIT 1;

  RETURN QUERY SELECT
    p_account,
    COALESCE(v_allowed, array[]::text[]),
    COALESCE(v_can_create, true),
    COALESCE(v_can_update, true),
    COALESCE(v_can_delete, true);
END;
$$;

REVOKE ALL ON FUNCTION public.my_feature_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_feature_permissions(uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.list_employees_with_email(p_account uuid)
RETURNS TABLE(
  user_uid uuid,
  email text,
  role text,
  disabled boolean,
  created_at timestamptz,
  employee_id uuid,
  doctor_id uuid
) AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  can_manage boolean;
  is_super boolean := public.fn_is_super_admin();
BEGIN
  EXECUTE 'set local row_security = off';

  SELECT EXISTS (
    SELECT 1
    FROM public.account_users
    WHERE account_id = p_account
      AND user_uid = caller_uid
      AND role IN ('owner','admin')
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
  LEFT JOIN public.employees e ON e.account_id = au.account_id AND e.user_uid = au.user_uid
  LEFT JOIN public.doctors d ON d.account_id = au.account_id AND d.user_uid = au.user_uid
  WHERE au.account_id = p_account
  ORDER BY au.created_at DESC;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth;

REVOKE ALL ON FUNCTION public.list_employees_with_email(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_employees_with_email(uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.delete_employee(
  p_account uuid,
  p_user_uid uuid
)
RETURNS void AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  can_manage boolean;
  is_super boolean := public.fn_is_super_admin();
BEGIN
  EXECUTE 'set local row_security = off';

  SELECT EXISTS (
    SELECT 1
    FROM public.account_users
    WHERE account_id = p_account
      AND user_uid = caller_uid
      AND role IN ('owner','admin')
      AND coalesce(disabled,false) = false
  ) INTO can_manage;

  IF NOT (can_manage OR is_super) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  DELETE FROM public.account_users
   WHERE account_id = p_account
     AND user_uid = p_user_uid;

  UPDATE public.employees
     SET user_uid = NULL,
         updated_at = now()
   WHERE account_id = p_account
     AND user_uid = p_user_uid;

  UPDATE public.doctors
     SET user_uid = NULL,
         updated_at = now()
   WHERE account_id = p_account
     AND user_uid = p_user_uid;

  UPDATE public.profiles
     SET role = 'removed'
   WHERE id = p_user_uid
     AND coalesce(account_id, p_account) = p_account;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth;

REVOKE ALL ON FUNCTION public.delete_employee(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_employee(uuid, uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_list_clinics()
RETURNS TABLE (
  id uuid,
  name text,
  frozen boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  allowed boolean := public.fn_is_super_admin();
BEGIN
  IF NOT allowed THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT a.id, a.name, a.frozen, a.created_at
  FROM public.accounts a
  ORDER BY a.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_clinics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_clinics() TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_set_clinic_frozen(
  p_account_id uuid,
  p_frozen boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  allowed boolean := public.fn_is_super_admin();
  updated_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  IF NOT allowed THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.accounts
     SET frozen = coalesce(p_frozen, false)
   WHERE id = p_account_id
   RETURNING id INTO updated_id;

  IF updated_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account not found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'account_id', updated_id::text, 'frozen', coalesce(p_frozen, false));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_delete_clinic(
  p_account_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  allowed boolean := public.fn_is_super_admin();
  deleted_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  IF NOT allowed THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  DELETE FROM public.accounts
   WHERE id = p_account_id
   RETURNING id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account not found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'account_id', deleted_id::text);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_clinic(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_clinic(uuid) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_create_owner_full(
  p_clinic_name text,
  p_owner_email text,
  p_owner_password text DEFAULT NULL
)
RETURNS jsonb
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
    RETURN jsonb_build_object('ok', false, 'error', 'clinic_name and owner_email are required');
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

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', acc_id::text
         ),
         raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', acc_id::text,
           'email_verified', true
         )
   WHERE id = owner_uid;

  RETURN jsonb_build_object(
    'ok', true,
    'account_id', acc_id::text,
    'owner_uid', owner_uid::text,
    'user_uid', owner_uid::text,
    'role', normalized_role
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_owner_full(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO public;

CREATE OR REPLACE FUNCTION public.admin_bootstrap_clinic_for_email(
  clinic_name text,
  owner_email text,
  owner_role text DEFAULT 'owner'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  normalized_clinic text := coalesce(nullif(trim(clinic_name), ''), '');
  normalized_email text := lower(coalesce(trim(owner_email), ''));
  normalized_role text := coalesce(nullif(trim(owner_role), ''), 'owner');
  clinic_id uuid;
  owner_uid uuid;
BEGIN
  IF normalized_clinic = '' THEN
    RAISE EXCEPTION 'clinic_name is required';
  END IF;

  IF normalized_email = '' THEN
    RAISE EXCEPTION 'owner_email is required';
  END IF;

  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  owner_uid := public.admin_resolve_or_create_auth_user(
    normalized_email,
    NULL,
    normalized_role
  );

  INSERT INTO public.accounts(name, frozen)
  VALUES (normalized_clinic, false)
  RETURNING id INTO clinic_id;

  PERFORM public.admin_attach_employee(clinic_id, owner_uid, normalized_role);

  UPDATE public.account_users
     SET email = normalized_email,
         role = normalized_role,
         disabled = false,
         updated_at = now()
   WHERE account_id = clinic_id
     AND user_uid = owner_uid;

  UPDATE public.profiles
     SET account_id = clinic_id,
         role = normalized_role,
         email = normalized_email,
         disabled = false,
         updated_at = now()
   WHERE id = owner_uid;

  UPDATE auth.users
     SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', clinic_id::text
         ),
         raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'account_id', clinic_id::text,
           'email_verified', true
         )
   WHERE id = owner_uid;

  RETURN clinic_id;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_bootstrap_clinic_for_email(
  clinic_name text,
  owner_email text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  RETURN public.admin_bootstrap_clinic_for_email(clinic_name, owner_email, 'owner');
END;
$$;

REVOKE ALL ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text) TO PUBLIC;

CREATE OR REPLACE FUNCTION public.admin_create_employee_full(
  p_account uuid,
  p_email text,
  p_password text DEFAULT NULL
)
RETURNS jsonb
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
    RAISE EXCEPTION 'account_id is required';
  END IF;

  IF normalized_email = '' THEN
    RAISE EXCEPTION 'email is required';
  END IF;

  SELECT EXISTS (
           SELECT 1 FROM public.accounts a WHERE a.id = p_account
         )
    INTO account_exists;

  IF NOT COALESCE(account_exists, false) THEN
    RAISE EXCEPTION 'account % not found', p_account;
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

  RETURN jsonb_build_object(
    'ok', true,
    'account_id', p_account::text,
    'user_uid', emp_uid::text,
    'role', normalized_role
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_employee_full(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO public;

COMMIT;
