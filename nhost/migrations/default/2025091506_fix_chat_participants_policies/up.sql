-- 2025091506_fix_chat_participants_policies (Nhost-safe)
-- Entire file is inside DO + EXECUTE to avoid parse-time failures.

DO $do$
DECLARE
  p text;
BEGIN
  IF to_regclass('public.chat_participants') IS NULL THEN
    RAISE NOTICE 'skip chat_participants policies: table missing';
    RETURN;
  END IF;

  -- Ensure RLS enabled (safe)
  EXECUTE 'ALTER TABLE public.chat_participants ENABLE ROW LEVEL SECURITY';

  -- Drop existing policies (safe)
  FOR p IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'chat_participants'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.chat_participants', p);
  END LOOP;

  -- SELECT: self or super-admin
  EXECUTE $sql$
    CREATE POLICY part_select_self_or_super
    ON public.chat_participants
    FOR SELECT
    TO PUBLIC
    USING (
      user_uid = nullif(public.request_uid_text(), '')::uuid
      OR fn_is_super_admin()
    );
  $sql$;

  -- UPDATE: self or super-admin
  EXECUTE $sql$
    CREATE POLICY part_update_self_or_super
    ON public.chat_participants
    FOR UPDATE
    TO PUBLIC
    USING (
      user_uid = nullif(public.request_uid_text(), '')::uuid
      OR fn_is_super_admin()
    )
    WITH CHECK (
      user_uid = nullif(public.request_uid_text(), '')::uuid
      OR fn_is_super_admin()
    );
  $sql$;

  -- INSERT/DELETE that reference chat_conversations: only if chat_conversations exists
  IF to_regclass('public.chat_conversations') IS NULL THEN
    RAISE NOTICE 'skip INSERT/DELETE policies: chat_conversations missing';
    RETURN;
  END IF;

  EXECUTE $sql$
    CREATE POLICY part_insert_by_creator_or_super
    ON public.chat_participants
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      fn_is_super_admin()
      OR EXISTS (
        SELECT 1
        FROM public.chat_conversations c
        WHERE c.id = chat_participants.conversation_id
          AND c.created_by = nullif(public.request_uid_text(), '')::uuid
      )
    );
  $sql$;

  EXECUTE $sql$
    CREATE POLICY part_delete_by_creator_or_super
    ON public.chat_participants
    FOR DELETE
    TO PUBLIC
    USING (
      fn_is_super_admin()
      OR EXISTS (
        SELECT 1
        FROM public.chat_conversations c
        WHERE c.id = chat_participants.conversation_id
          AND c.created_by = nullif(public.request_uid_text(), '')::uuid
      )
    );
  $sql$;

END
$do$;
