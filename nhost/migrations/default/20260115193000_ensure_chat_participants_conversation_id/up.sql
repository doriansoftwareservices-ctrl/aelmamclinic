BEGIN;

ALTER TABLE public.chat_participants
  ADD COLUMN IF NOT EXISTS conversation_id uuid;

COMMIT;
