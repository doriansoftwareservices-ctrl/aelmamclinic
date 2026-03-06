DO $$
BEGIN
  IF to_regclass('public.push_device_tokens') IS NULL THEN
    CREATE TABLE public.push_device_tokens (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_uid uuid NOT NULL,
      account_id uuid,
      role text,
      platform text,
      token text NOT NULL,
      is_active boolean NOT NULL DEFAULT true,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    );

    CREATE UNIQUE INDEX push_device_tokens_token_key
      ON public.push_device_tokens(token);
    CREATE UNIQUE INDEX push_device_tokens_user_token_key
      ON public.push_device_tokens(user_uid, token);
  END IF;

  ALTER TABLE public.push_device_tokens ENABLE ROW LEVEL SECURITY;

  DROP POLICY IF EXISTS push_device_tokens_select_own ON public.push_device_tokens;
  DROP POLICY IF EXISTS push_device_tokens_insert_own ON public.push_device_tokens;
  DROP POLICY IF EXISTS push_device_tokens_update_own ON public.push_device_tokens;

  CREATE POLICY push_device_tokens_select_own ON public.push_device_tokens
    FOR SELECT TO PUBLIC
    USING (
      public.fn_is_super_admin() = true OR
      user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
    );

  CREATE POLICY push_device_tokens_insert_own ON public.push_device_tokens
    FOR INSERT TO PUBLIC
    WITH CHECK (
      user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
    );

  CREATE POLICY push_device_tokens_update_own ON public.push_device_tokens
    FOR UPDATE TO PUBLIC
    USING (
      user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
    )
    WITH CHECK (
      user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
    );
END $$;
