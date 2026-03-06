BEGIN;

ALTER TABLE IF EXISTS public.chat_attachments
  ALTER COLUMN bucket SET DEFAULT 'chat-images';

COMMIT;
