BEGIN;

-- Ensure core chat columns exist (id/conversation_id/message_id) to satisfy Hasura metadata.
DO $$
BEGIN
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_conversations'
        AND column_name = 'id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_conversations ADD COLUMN id uuid DEFAULT gen_random_uuid()';
      EXECUTE 'UPDATE public.chat_conversations SET id = gen_random_uuid() WHERE id IS NULL';
    END IF;
  END IF;

  IF to_regclass('public.chat_participants') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_participants'
        AND column_name = 'conversation_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_participants ADD COLUMN conversation_id uuid';
    END IF;
  END IF;

  IF to_regclass('public.chat_delivery_receipts') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_delivery_receipts'
        AND column_name = 'message_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_delivery_receipts ADD COLUMN message_id uuid';
    END IF;
  END IF;

  IF to_regclass('public.chat_reactions') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_reactions'
        AND column_name = 'message_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_reactions ADD COLUMN message_id uuid';
    END IF;
  END IF;

  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_attachments'
        AND column_name = 'message_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_attachments ADD COLUMN message_id uuid';
    END IF;
  END IF;
END$$;

COMMIT;
