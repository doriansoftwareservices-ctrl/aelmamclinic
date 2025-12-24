-- Bootstrap chat tables for fresh Nhost DB (idempotent)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid,
  is_group boolean NOT NULL DEFAULT false,
  title text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_msg_at timestamptz,
  last_msg_snippet text
);

CREATE TABLE IF NOT EXISTS public.chat_participants (
  conversation_id uuid NOT NULL,
  user_uid uuid NOT NULL,
  role text,
  email text,
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_uid)
);

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL,
  account_id uuid,
  sender_uid uuid,
  sender_email text,
  body text,
  kind text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text,
  local_id bigint
);

CREATE TABLE IF NOT EXISTS public.chat_reads (
  conversation_id uuid NOT NULL,
  user_uid uuid NOT NULL,
  last_read_at timestamptz,
  last_read_msg_id uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_uid)
);

CREATE TABLE IF NOT EXISTS public.chat_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL,
  user_uid uuid NOT NULL,
  reaction text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
