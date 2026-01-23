ALTER TABLE public.chat_attachments
  DROP CONSTRAINT IF EXISTS chat_attachments_message_id_fkey;

DROP INDEX IF EXISTS idx_chat_attachments_message_id;

ALTER TABLE public.chat_attachments
  DROP COLUMN IF EXISTS message_id;
