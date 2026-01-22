BEGIN;

DO $$
BEGIN
  IF to_regclass('public.chat_attachments') IS NOT NULL THEN

    -- add message_id if missing
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema='public'
        AND table_name='chat_attachments'
        AND column_name='message_id'
    ) THEN
      ALTER TABLE public.chat_attachments
        ADD COLUMN message_id uuid;
    END IF;

    -- add FK if missing
    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'chat_attachments_message_id_fkey'
    ) THEN
      ALTER TABLE public.chat_attachments
        ADD CONSTRAINT chat_attachments_message_id_fkey
        FOREIGN KEY (message_id)
        REFERENCES public.chat_messages(id)
        ON DELETE CASCADE;
    END IF;

    -- add index if missing
    IF NOT EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'idx_chat_attachments_message_id'
    ) THEN
      CREATE INDEX idx_chat_attachments_message_id
        ON public.chat_attachments (message_id);
    END IF;

  END IF;
END
$$;

COMMIT;
