-- 20251026000000_staff_user_uid.sql
-- Adds user_uid tracking columns for employees/doctors and keeps helper RPCs aligned.

ALTER TABLE public.doctors
  ADD COLUMN IF NOT EXISTS user_uid uuid;
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS user_uid uuid;
CREATE UNIQUE INDEX IF NOT EXISTS doctors_user_uid_key
  ON public.doctors(user_uid)
  WHERE user_uid IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS employees_user_uid_key
  ON public.employees(user_uid)
  WHERE user_uid IS NOT NULL;
-- Ensure admin_attach_employee honors the new constraint.
CREATE OR REPLACE FUNCTION public.admin_attach_employee(
  p_account uuid,
  p_user_uid uuid,
  p_role text DEFAULT 'employee'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  exists_row boolean;
BEGIN
  IF p_account IS NULL OR p_user_uid IS NULL THEN
    RAISE EXCEPTION 'account_id and user_uid are required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.employees e
    WHERE e.user_uid = p_user_uid
      AND e.account_id IS DISTINCT FROM p_account
  ) THEN
    RAISE EXCEPTION 'user already linked to another employee record' USING errcode = '23505';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.doctors d
    WHERE d.user_uid = p_user_uid
      AND d.account_id IS DISTINCT FROM p_account
  ) THEN
    RAISE EXCEPTION 'user already linked to another doctor record' USING errcode = '23505';
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
    WHERE table_schema='public' AND table_name='profiles'
  ) THEN
    INSERT INTO public.profiles(id, account_id, role, created_at)
    VALUES (p_user_uid, p_account, COALESCE(p_role, 'employee'), now())
    ON CONFLICT (id) DO UPDATE
        SET account_id = EXCLUDED.account_id,
            role = EXCLUDED.role;
  END IF;
END;
$$;
-- Expand list_employees_with_email to expose link status.
DROP FUNCTION IF EXISTS public.list_employees_with_email(uuid);
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
GRANT EXECUTE ON FUNCTION public.list_employees_with_email(uuid) TO PUBLIC;
-- When removing a link, clear the staff user reference so it can be reused.
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
