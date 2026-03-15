BEGIN;

DO $$
BEGIN
  IF to_regclass('public.chat_reactions') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_reactions'
        AND column_name = 'message_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_reactions ADD COLUMN message_id uuid';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_indexes
      WHERE schemaname = 'public'
        AND tablename = 'chat_reactions'
        AND indexname = 'chat_reactions_message_idx'
    ) THEN
      EXECUTE 'CREATE INDEX chat_reactions_message_idx ON public.chat_reactions (message_id)';
    END IF;
  END IF;
END $$;

COMMIT;
