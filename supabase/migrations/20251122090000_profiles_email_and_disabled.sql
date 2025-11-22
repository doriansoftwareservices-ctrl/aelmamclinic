-- 20251122090000_profiles_email_and_disabled.sql
-- Aligns public.profiles with application expectations (email/disabled columns)
-- and keeps it in sync with account_users when provisioning new accounts.

BEGIN;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS disabled boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS profiles_email_lower_idx
  ON public.profiles (lower(email));

-- backfill email from auth.users when available
UPDATE public.profiles AS p
SET email = lower(u.email)
FROM auth.users u
WHERE p.email IS NULL
  AND u.id = p.id;

-- backfill disabled flag and restore roles from account_users
UPDATE public.profiles AS p
SET disabled = coalesce(au.disabled, false)
FROM public.account_users au
WHERE au.user_uid = p.id
  AND (p.account_id IS NULL OR au.account_id = p.account_id);

UPDATE public.profiles AS p
SET role = coalesce(au.role, p.role),
    disabled = true
FROM public.account_users au
WHERE au.user_uid = p.id
  AND (p.account_id IS NULL OR au.account_id = p.account_id)
  AND lower(coalesce(p.role, '')) = 'disabled';

-- keep profiles in sync with account_users mutations
CREATE OR REPLACE FUNCTION public.tg_account_users_sync_profile()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  target_email text := lower(coalesce(NEW.email, ''));
BEGIN
  UPDATE public.profiles AS p
     SET account_id = NEW.account_id,
         role = coalesce(NEW.role, p.role),
         email = CASE WHEN target_email <> '' THEN target_email ELSE p.email END,
         disabled = coalesce(NEW.disabled, p.disabled)
   WHERE p.id = NEW.user_uid;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS account_users_sync_profile ON public.account_users;
CREATE TRIGGER account_users_sync_profile
AFTER INSERT OR UPDATE ON public.account_users
FOR EACH ROW
EXECUTE FUNCTION public.tg_account_users_sync_profile();

-- refresh admin_attach_employee to populate the new fields
CREATE OR REPLACE FUNCTION public.admin_attach_employee(
  p_account uuid,
  p_user_uid uuid,
  p_role text DEFAULT 'employee'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  exists_row boolean;
  caller_can_manage boolean;
  normalized_role text := coalesce(nullif(trim(p_role), ''), 'employee');
  normalized_email text;
BEGIN
  IF p_account IS NULL OR p_user_uid IS NULL THEN
    RAISE EXCEPTION 'account_id and user_uid are required';
  END IF;

  SELECT lower(coalesce(email, ''))
    INTO normalized_email
    FROM auth.users
   WHERE id = p_user_uid
   ORDER BY created_at DESC
   LIMIT 1;

  IF fn_is_super_admin() = false THEN
    SELECT EXISTS (
             SELECT 1
               FROM public.account_users au
              WHERE au.account_id = p_account
                AND au.user_uid::text = auth.uid()::text
                AND COALESCE(au.disabled, false) = false
                AND lower(COALESCE(au.role, '')) = 'owner'
           )
      INTO caller_can_manage;

    IF NOT COALESCE(caller_can_manage, false) THEN
      RAISE EXCEPTION 'insufficient privileges to manage employees for this account'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT true INTO exists_row
    FROM public.account_users
   WHERE account_id = p_account
     AND user_uid = p_user_uid
   LIMIT 1;

  IF NOT COALESCE(exists_row, false) THEN
    INSERT INTO public.account_users(account_id, user_uid, role, disabled, email)
    VALUES (p_account, p_user_uid, normalized_role, false, nullif(normalized_email, ''));
  ELSE
    UPDATE public.account_users
       SET disabled = false,
           role = normalized_role,
           email = COALESCE(nullif(normalized_email, ''), email),
           updated_at = now()
     WHERE account_id = p_account
       AND user_uid = p_user_uid;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'profiles'
  ) THEN
    INSERT INTO public.profiles(id, account_id, role, email, disabled, created_at)
    VALUES (
      p_user_uid,
      p_account,
      normalized_role,
      nullif(normalized_email, ''),
      false,
      now()
    )
    ON CONFLICT (id) DO UPDATE
        SET account_id = EXCLUDED.account_id,
            role = EXCLUDED.role,
            email = COALESCE(EXCLUDED.email, public.profiles.email),
            disabled = false;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_attach_employee(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_attach_employee(uuid, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO service_role;

-- keep set_employee_disabled in sync with the new column
DROP FUNCTION IF EXISTS public.set_employee_disabled(uuid, uuid, boolean);
CREATE OR REPLACE FUNCTION public.set_employee_disabled(
  p_account uuid,
  p_user_uid uuid,
  p_disabled boolean
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  can_manage boolean;
  is_super_admin boolean := public.fn_is_super_admin();
  target_role text;
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

  UPDATE public.account_users
     SET disabled = coalesce(p_disabled, false)
   WHERE account_id = p_account
     AND user_uid = p_user_uid;

  SELECT nullif(lower(coalesce(role, '')), '')
    INTO target_role
    FROM public.account_users
   WHERE account_id = p_account
     AND user_uid = p_user_uid
   LIMIT 1;

  UPDATE public.profiles
     SET role = coalesce(target_role, role),
         account_id = coalesce(account_id, p_account),
         disabled = coalesce(p_disabled, false)
   WHERE id = p_user_uid;
END;
$$;
REVOKE ALL ON FUNCTION public.set_employee_disabled(uuid, uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.set_employee_disabled(uuid, uuid, boolean) TO authenticated;

COMMIT;
