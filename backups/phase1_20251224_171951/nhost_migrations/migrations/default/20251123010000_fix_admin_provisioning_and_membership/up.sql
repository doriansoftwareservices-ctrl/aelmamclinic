-- 20251123010000_fix_admin_provisioning_and_membership.sql
-- Resolves recursive account membership checks (stack depth failures) and
-- teaches the admin RPCs to create/link auth users directly so that the
-- Flutter super-admin panel can provision owners/employees reliably.

BEGIN;

-- Helper: resolve or create an auth user with the supplied credentials/role.
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
  escalated boolean := false;
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
    IF normalized_password IS NULL THEN
      RAISE EXCEPTION 'password is required to create user %', normalized_email
        USING ERRCODE = '22023';
    END IF;

    BEGIN
      EXECUTE 'set local role supabase_auth_admin';
      escalated := true;

      SELECT id
        INTO target_uid
        FROM auth.create_user(
          jsonb_build_object(
            'email', normalized_email,
            'password', normalized_password,
            'email_confirm', true,
            'app_metadata', jsonb_build_object(
              'role', normalized_role,
              'provider', 'email',
              'providers', jsonb_build_array('email')
            ),
            'user_metadata', jsonb_build_object(
              'role', normalized_role,
              'email_verified', true
            )
          )
        );
    EXCEPTION
      WHEN OTHERS THEN
        IF escalated THEN
          BEGIN
            EXECUTE 'reset role';
          EXCEPTION
            WHEN OTHERS THEN NULL;
          END;
          escalated := false;
        END IF;
        RAISE;
    END;

    IF escalated THEN
      BEGIN
        EXECUTE 'reset role';
      EXCEPTION
        WHEN OTHERS THEN NULL;
      END;
      escalated := false;
    END IF;
  END IF;

  UPDATE auth.users
     SET email_confirmed_at = COALESCE(email_confirmed_at, now()),
         raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'provider', 'email',
           'providers', jsonb_build_array('email')
         ),
         raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object(
           'role', normalized_role,
           'email_verified', true
         )
   WHERE id = target_uid;

  RETURN target_uid;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_resolve_or_create_auth_user(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_resolve_or_create_auth_user(text, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_resolve_or_create_auth_user(text, text, text) TO public;

-- Fix fn_is_account_member recursion by temporarily elevating the role.
CREATE OR REPLACE FUNCTION public.fn_is_account_member(p_account uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result boolean := false;
  escalated boolean := false;
BEGIN
  IF p_account IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    EXECUTE 'set local role postgres';
    escalated := true;

    SELECT EXISTS (
      SELECT 1
        FROM public.account_users au
       WHERE au.account_id = p_account
         AND au.user_uid::text = public.request_uid_text()::text
         AND COALESCE(au.disabled, false) = false
    )
    INTO result;
  EXCEPTION
    WHEN OTHERS THEN
      IF escalated THEN
        BEGIN
          EXECUTE 'reset role';
        EXCEPTION
          WHEN OTHERS THEN NULL;
        END;
        escalated := false;
      END IF;
      RAISE;
  END;

  IF escalated THEN
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

-- Admin RPC: create/attach clinic owner (auth user auto-created when needed).
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
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
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

  IF fn_is_super_admin() IS DISTINCT FROM true THEN
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

-- Keep admin_bootstrap_clinic_for_email in sync with the new helper.
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
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
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

  IF fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
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

-- Admin RPC: create/attach employee (auth user auto-created when needed).
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
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  normalized_email text := lower(coalesce(trim(p_email), ''));
  normalized_role text := 'employee';
  normalized_password text := nullif(coalesce(trim(p_password), ''), '');
  emp_uid uuid;
  account_exists boolean;
BEGIN
  IF fn_is_super_admin() IS DISTINCT FROM true THEN
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
