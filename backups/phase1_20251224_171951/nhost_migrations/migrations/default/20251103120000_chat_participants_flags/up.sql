-- 20251103120000_chat_participants_flags.sql
-- Add conversation preferences to chat_participants (pinned/archived/blocked/last_read_at/display_name).

ALTER TABLE public.chat_participants
  ADD COLUMN IF NOT EXISTS display_name text;

ALTER TABLE public.chat_participants
  ADD COLUMN IF NOT EXISTS pinned boolean;
ALTER TABLE public.chat_participants
  ADD COLUMN IF NOT EXISTS archived boolean;
ALTER TABLE public.chat_participants
  ADD COLUMN IF NOT EXISTS blocked boolean;
ALTER TABLE public.chat_participants
  ADD COLUMN IF NOT EXISTS last_read_at timestamptz;

UPDATE public.chat_participants
SET
  pinned = COALESCE(pinned, false),
  archived = COALESCE(archived, false),
  blocked = COALESCE(blocked, false),
  last_read_at = COALESCE(last_read_at, joined_at, timezone('utc', now()));

ALTER TABLE public.chat_participants
  ALTER COLUMN pinned SET DEFAULT false,
  ALTER COLUMN pinned SET NOT NULL,
  ALTER COLUMN archived SET DEFAULT false,
  ALTER COLUMN archived SET NOT NULL,
  ALTER COLUMN blocked SET DEFAULT false,
  ALTER COLUMN blocked SET NOT NULL,
  ALTER COLUMN last_read_at SET DEFAULT timezone('utc', now()),
  ALTER COLUMN last_read_at SET NOT NULL;

COMMENT ON COLUMN public.chat_participants.pinned IS 'Pinned conversations for the current participant.';
COMMENT ON COLUMN public.chat_participants.archived IS 'Archived conversations for the current participant.';
COMMENT ON COLUMN public.chat_participants.blocked IS 'Whether the participant blocked notifications from this conversation.';
COMMENT ON COLUMN public.chat_participants.last_read_at IS 'Latest time the participant read the conversation (UTC).';
