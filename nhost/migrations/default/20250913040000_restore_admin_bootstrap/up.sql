-- fix: ensure clean create by dropping old version (arg defaults cause 42P13)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'admin_create_employee_full'
      AND p.proargtypes = ARRAY['uuid'::regtype,'text'::regtype,'text'::regtype]::oidvector
  ) THEN
    DROP FUNCTION public.admin_create_employee_full(uuid, text, text);
  END IF;
END$$;
-- 20250913040000_restore_admin_bootstrap.sql
-- Restores the SECURITY DEFINER helper used by admin flows and edge functions
-- to bootstrap a clinic and attach the owner user.

CREATE OR REPLACE FUNCTION public.admin_bootstrap_clinic_for_email(
  clinic_name text,
  owner_email text,
  owner_role text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  normalized_email text := lower(coalesce(trim(owner_email), ''));
  normalized_role text := coalesce(nullif(trim(owner_role), ''), 'owner');
  owner_uid uuid;
  acc_id uuid;
BEGIN
  IF coalesce(trim(clinic_name), '') = '' THEN
    RAISE EXCEPTION 'clinic_name is required';
  END IF;

  IF normalized_email = '' THEN
    RAISE EXCEPTION 'owner_email is required';
  END IF;

  IF fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT id
    INTO owner_uid
  FROM auth.users
  WHERE lower(email) = normalized_email
  ORDER BY created_at DESC
  LIMIT 1;

  IF owner_uid IS NULL THEN
    RAISE EXCEPTION 'owner with email % not found in auth.users', normalized_email;
  END IF;

  INSERT INTO public.accounts(name, frozen)
  VALUES (clinic_name, false)
  RETURNING id INTO acc_id;

  PERFORM public.admin_attach_employee(acc_id, owner_uid, normalized_role);

  UPDATE public.account_users
     SET email = normalized_email,
         role = normalized_role,
         updated_at = now()
   WHERE account_id = acc_id
     AND user_uid = owner_uid;

  RETURN acc_id;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text, text) TO public;

CREATE OR REPLACE FUNCTION public.admin_create_employee_full(
  p_account uuid,
  p_email text,
  p_password text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
  v_account uuid := p_account;
  v_email text := nullif(lower(trim(p_email)), '');
  v_uid uuid;
BEGIN
  IF NOT v_is_super THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'account_id is required';
  END IF;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'email is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.accounts WHERE id = v_account) THEN
    RAISE EXCEPTION 'account % not found', v_account;
  END IF;

  SELECT u.id
    INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  ORDER BY u.created_at DESC
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'user with email % not found in auth.users', v_email;
  END IF;

  PERFORM public.admin_attach_employee(v_account, v_uid, 'employee');

  UPDATE public.account_users
     SET email = v_email,
         updated_at = now()
   WHERE account_id = v_account
     AND user_uid = v_uid;

  RETURN jsonb_build_object(
    'ok', true,
    'account_id', v_account,
    'user_uid', v_uid
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_employee_full(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO PUBLIC;
