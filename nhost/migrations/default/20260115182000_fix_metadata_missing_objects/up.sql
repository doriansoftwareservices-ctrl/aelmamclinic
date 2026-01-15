BEGIN;

-- Ensure user_current_account exists for permissions that reference it.
CREATE TABLE IF NOT EXISTS public.user_current_account (
  user_uid uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_current_account ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'tg_touch_updated_at'
  ) THEN
    EXECUTE 'DROP TRIGGER IF EXISTS user_current_account_touch ON public.user_current_account';
    EXECUTE 'CREATE TRIGGER user_current_account_touch
      BEFORE UPDATE ON public.user_current_account
      FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at()';
  END IF;
END$$;

DROP POLICY IF EXISTS user_current_account_select_self ON public.user_current_account;
CREATE POLICY user_current_account_select_self
ON public.user_current_account
FOR SELECT
TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR user_uid = nullif(public.request_uid_text(), '')::uuid
);

DROP POLICY IF EXISTS user_current_account_insert_self ON public.user_current_account;
CREATE POLICY user_current_account_insert_self
ON public.user_current_account
FOR INSERT
TO PUBLIC
WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = user_current_account.account_id
      AND au.user_uid = user_current_account.user_uid
      AND coalesce(au.disabled, false) = false
  )
);

DROP POLICY IF EXISTS user_current_account_update_self ON public.user_current_account;
CREATE POLICY user_current_account_update_self
ON public.user_current_account
FOR UPDATE
TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR user_uid = nullif(public.request_uid_text(), '')::uuid
)
WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = user_current_account.account_id
      AND au.user_uid = user_current_account.user_uid
      AND coalesce(au.disabled, false) = false
  )
);

DROP POLICY IF EXISTS user_current_account_delete_self ON public.user_current_account;
CREATE POLICY user_current_account_delete_self
ON public.user_current_account
FOR DELETE
TO PUBLIC
USING (
  public.fn_is_super_admin() = true
  OR user_uid = nullif(public.request_uid_text(), '')::uuid
);

-- Ensure chat_participants.conversation_id exists.
DO $$
BEGIN
  IF to_regclass('public.chat_participants') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_participants'
        AND column_name = 'conversation_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_participants ADD COLUMN conversation_id uuid';
    END IF;
  END IF;
END$$;

-- Recreate admin_reply_complaint with v_rpc_result return type for Hasura tracking.
DROP FUNCTION IF EXISTS public.admin_reply_complaint(uuid, text, text);
CREATE OR REPLACE FUNCTION public.admin_reply_complaint(
  p_id uuid,
  p_reply text,
  p_status text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'not_authenticated', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.fn_is_super_admin() IS NOT TRUE THEN
    RETURN QUERY SELECT false, 'super_admin_only', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_id IS NULL THEN
    RETURN QUERY SELECT false, 'missing_id', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  UPDATE public.complaints
     SET reply_message = p_reply,
         replied_at = now(),
         replied_by = v_uid,
         handled_by = v_uid,
         handled_at = now(),
         status = COALESCE(NULLIF(trim(p_status), ''), status)
   WHERE id = p_id
   RETURNING account_id INTO v_account;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'not_found', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::text, v_account, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reply_complaint(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reply_complaint(uuid, text, text) TO public;

-- Recreate update_clinic_profile with v_rpc_result return type for Hasura tracking.
DROP FUNCTION IF EXISTS public.update_clinic_profile(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
);
CREATE OR REPLACE FUNCTION public.update_clinic_profile(
  p_clinic_name text,
  p_city_ar text,
  p_street_ar text,
  p_near_ar text,
  p_clinic_name_en text,
  p_city_en text,
  p_street_en text,
  p_near_en text,
  p_phone text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'unauthenticated', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_clinic_name IS NULL OR btrim(p_clinic_name) = '' THEN
    RETURN QUERY SELECT false, 'clinic_name_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF p_city_ar IS NULL OR btrim(p_city_ar) = '' THEN
    RETURN QUERY SELECT false, 'city_ar_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF p_street_ar IS NULL OR btrim(p_street_ar) = '' THEN
    RETURN QUERY SELECT false, 'street_ar_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF p_near_ar IS NULL OR btrim(p_near_ar) = '' THEN
    RETURN QUERY SELECT false, 'near_ar_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF p_clinic_name_en IS NULL OR btrim(p_clinic_name_en) = '' THEN
    RETURN QUERY SELECT false, 'clinic_name_en_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF p_city_en IS NULL OR btrim(p_city_en) = '' THEN
    RETURN QUERY SELECT false, 'city_en_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF p_street_en IS NULL OR btrim(p_street_en) = '' THEN
    RETURN QUERY SELECT false, 'street_en_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF p_near_en IS NULL OR btrim(p_near_en) = '' THEN
    RETURN QUERY SELECT false, 'near_en_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF p_phone IS NULL OR btrim(p_phone) = '' THEN
    RETURN QUERY SELECT false, 'phone_required', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
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
    RETURN QUERY SELECT false, 'account_not_found', NULL::uuid, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF public.fn_is_super_admin() IS NOT TRUE
     AND lower(coalesce(v_role, '')) NOT IN ('owner', 'admin') THEN
    RETURN QUERY SELECT false, 'forbidden', v_account, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  UPDATE public.accounts
     SET name = p_clinic_name,
         clinic_name_en = p_clinic_name_en,
         city_ar = p_city_ar,
         street_ar = p_street_ar,
         near_ar = p_near_ar,
         city_en = p_city_en,
         street_en = p_street_en,
         near_en = p_near_en,
         phone = p_phone
   WHERE id = v_account;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'update_failed', v_account, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::text, v_account, v_uid, NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
END;
$$;

REVOKE ALL ON FUNCTION public.update_clinic_profile(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_clinic_profile(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) TO PUBLIC;

COMMIT;
