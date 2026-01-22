BEGIN;

DO $$
BEGIN
  IF to_regclass('public.chat_attachments') IS NOT NULL THEN

    IF EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conname = 'chat_attachments_message_id_fkey'
    ) THEN
      ALTER TABLE public.chat_attachments
        DROP CONSTRAINT chat_attachments_message_id_fkey;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'idx_chat_attachments_message_id'
    ) THEN
      DROP INDEX public.idx_chat_attachments_message_id;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema='public'
        AND table_name='chat_attachments'
        AND column_name='message_id'
    ) THEN
      ALTER TABLE public.chat_attachments
        DROP COLUMN message_id;
    END IF;

  END IF;
END;
$$;

COMMIT;
