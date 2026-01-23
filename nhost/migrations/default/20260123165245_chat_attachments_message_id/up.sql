ALTER TABLE public.chat_attachments
  ADD COLUMN IF NOT EXISTS message_id uuid;

ALTER TABLE public.chat_attachments
  DROP CONSTRAINT IF EXISTS chat_attachments_message_id_fkey;

ALTER TABLE public.chat_attachments
  ADD CONSTRAINT chat_attachments_message_id_fkey
  FOREIGN KEY (message_id)
  REFERENCES public.chat_messages(id)
  ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_chat_attachments_message_id
  ON public.chat_attachments (message_id);
