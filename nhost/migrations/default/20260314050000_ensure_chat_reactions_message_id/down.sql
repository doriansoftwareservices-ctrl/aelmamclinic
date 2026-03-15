BEGIN;

DO $$
BEGIN
  IF to_regclass('public.chat_reactions') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename = 'chat_reactions'
        AND indexname = 'chat_reactions_message_idx'
    ) THEN
      EXECUTE 'DROP INDEX public.chat_reactions_message_idx';
    END IF;
  END IF;
END $$;

COMMIT;
