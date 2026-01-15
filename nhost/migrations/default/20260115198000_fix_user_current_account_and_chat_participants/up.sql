BEGIN;

-- Ensure user_current_account exists for Hasura permissions.
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

-- Ensure chat_participants.conversation_id exists (older schemas may lack it).
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

-- Ensure subscription_requests optional columns exist.
ALTER TABLE public.subscription_requests
  ADD COLUMN IF NOT EXISTS clinic_name text,
  ADD COLUMN IF NOT EXISTS reference_text text,
  ADD COLUMN IF NOT EXISTS sender_name text;

COMMIT;
