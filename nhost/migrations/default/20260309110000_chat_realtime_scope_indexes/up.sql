-- Improve chat realtime scope lookups by user/account while respecting soft-delete.
DO $$
DECLARE
  has_is_deleted boolean;
BEGIN
  IF to_regclass('public.chat_participants') IS NULL THEN
    RAISE NOTICE 'skip chat_realtime_scope_indexes: chat_participants table missing';
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_participants'
      AND column_name = 'is_deleted'
  )
  INTO has_is_deleted;

  IF has_is_deleted THEN
    EXECUTE '
      CREATE INDEX IF NOT EXISTS idx_chat_participants_uid_account_active
      ON public.chat_participants (user_uid, account_id, conversation_id)
      WHERE COALESCE(is_deleted, false) = false
    ';
    EXECUTE '
      CREATE INDEX IF NOT EXISTS idx_chat_participants_uid_active
      ON public.chat_participants (user_uid, conversation_id)
      WHERE COALESCE(is_deleted, false) = false
    ';
  ELSE
    EXECUTE '
      CREATE INDEX IF NOT EXISTS idx_chat_participants_uid_account_active
      ON public.chat_participants (user_uid, account_id, conversation_id)
    ';
    EXECUTE '
      CREATE INDEX IF NOT EXISTS idx_chat_participants_uid_active
      ON public.chat_participants (user_uid, conversation_id)
    ';
  END IF;
END $$;
