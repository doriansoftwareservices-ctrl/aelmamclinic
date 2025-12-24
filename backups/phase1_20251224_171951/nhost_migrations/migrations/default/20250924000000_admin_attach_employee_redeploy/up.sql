-- Deploy admin_attach_employee hardening to existing environments
BEGIN;
CREATE OR REPLACE FUNCTION public.admin_attach_employee(p_account uuid, p_user_uid uuid, p_role text DEFAULT 'employee')
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  exists_row boolean;
  caller_can_manage boolean;
BEGIN
  IF p_account IS NULL OR p_user_uid IS NULL THEN
    RAISE EXCEPTION 'account_id and user_uid are required';
  END IF;

  IF fn_is_super_admin() = false THEN
    SELECT EXISTS (
             SELECT 1
               FROM public.account_users au
              WHERE au.account_id = p_account
                AND au.user_uid::text = public.request_uid_text()::uuid::text
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
COMMIT;
