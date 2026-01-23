BEGIN;

DO $do$
BEGIN
  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.chat_attachments DROP CONSTRAINT IF EXISTS chat_attachments_message_id_fkey';
    EXECUTE 'DROP INDEX IF EXISTS idx_chat_attachments_message_id';
  END IF;
END
$do$;

COMMIT;
