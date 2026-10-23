-- Private local PostgreSQL fixture only. Never run against an Nhost database.
CREATE SCHEMA auth;
CREATE SCHEMA storage;
CREATE TABLE public.elmam_chat_fixture_marker (value text PRIMARY KEY);
INSERT INTO public.elmam_chat_fixture_marker VALUES ('local_chat_attachment_scope_20261016');

CREATE FUNCTION public.fixture_uuid(value integer) RETURNS uuid
LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-4000-8000-' || lpad(value::text, 12, '0'))::uuid
$$;
CREATE TABLE auth.users (id uuid PRIMARY KEY, disabled boolean DEFAULT false);
CREATE TABLE public.accounts (id uuid PRIMARY KEY, frozen boolean DEFAULT false);
CREATE TABLE public.account_users (
  account_id uuid REFERENCES public.accounts, user_uid uuid REFERENCES auth.users,
  role text, disabled boolean DEFAULT false, PRIMARY KEY (account_id, user_uid)
);
CREATE TABLE public.super_admins (
  user_uid uuid PRIMARY KEY REFERENCES auth.users, disabled boolean DEFAULT false
);
CREATE TABLE public.chat_conversations (
  id uuid PRIMARY KEY, account_id uuid REFERENCES public.accounts
);
CREATE TABLE public.chat_participants (
  conversation_id uuid REFERENCES public.chat_conversations,
  user_uid uuid REFERENCES auth.users, role text, is_deleted boolean DEFAULT false,
  PRIMARY KEY (conversation_id, user_uid)
);
CREATE TABLE public.chat_messages (
  id uuid PRIMARY KEY, conversation_id uuid REFERENCES public.chat_conversations,
  account_id uuid REFERENCES public.accounts, sender_uid uuid REFERENCES auth.users,
  is_deleted boolean DEFAULT false, deleted boolean DEFAULT false
);
CREATE TABLE public.chat_attachments (
  id uuid PRIMARY KEY, message_id uuid REFERENCES public.chat_messages,
  account_id uuid REFERENCES public.accounts, bucket text, path text,
  is_deleted boolean DEFAULT false
);
CREATE TABLE storage.buckets (id text PRIMARY KEY);
CREATE TABLE storage.files (
  id uuid PRIMARY KEY, bucket_id text REFERENCES storage.buckets,
  name text, uploaded_by_user_id uuid REFERENCES auth.users
);

INSERT INTO public.accounts SELECT public.fixture_uuid(n), false FROM generate_series(1, 3) n;
INSERT INTO auth.users SELECT public.fixture_uuid(n), n = 17 FROM generate_series(11, 22) n;
INSERT INTO public.account_users (account_id, user_uid, role, disabled) VALUES
  (public.fixture_uuid(1), public.fixture_uuid(11), 'owner', false),
  (public.fixture_uuid(1), public.fixture_uuid(12), 'employee', false),
  (public.fixture_uuid(2), public.fixture_uuid(13), 'owner', false),
  (public.fixture_uuid(3), public.fixture_uuid(14), 'owner', false),
  (public.fixture_uuid(1), public.fixture_uuid(17), 'owner', false),
  (public.fixture_uuid(1), public.fixture_uuid(18), 'owner', false),
  (public.fixture_uuid(2), public.fixture_uuid(19), 'owner', true),
  (public.fixture_uuid(2), public.fixture_uuid(22), 'employee', false);
INSERT INTO public.super_admins VALUES
  (public.fixture_uuid(15), false), (public.fixture_uuid(20), true),
  (public.fixture_uuid(21), false);
INSERT INTO public.chat_conversations VALUES
  (public.fixture_uuid(31), public.fixture_uuid(1)),
  (public.fixture_uuid(32), NULL), (public.fixture_uuid(33), NULL);
INSERT INTO public.chat_participants (conversation_id, user_uid, role, is_deleted) VALUES
  (public.fixture_uuid(31), public.fixture_uuid(11), 'owner', false),
  (public.fixture_uuid(31), public.fixture_uuid(12), 'member', false),
  (public.fixture_uuid(31), public.fixture_uuid(13), 'owner', false),
  (public.fixture_uuid(31), public.fixture_uuid(17), 'owner', false),
  (public.fixture_uuid(32), public.fixture_uuid(11), 'owner', false),
  (public.fixture_uuid(32), public.fixture_uuid(13), 'owner', false),
  (public.fixture_uuid(32), public.fixture_uuid(12), 'member', false),
  (public.fixture_uuid(32), public.fixture_uuid(16), 'owner', false),
  (public.fixture_uuid(32), public.fixture_uuid(18), 'owner', true),
  (public.fixture_uuid(32), public.fixture_uuid(19), 'owner', false),
  (public.fixture_uuid(32), public.fixture_uuid(20), 'admin', false),
  (public.fixture_uuid(32), public.fixture_uuid(22), 'member', false),
  (public.fixture_uuid(33), public.fixture_uuid(14), 'owner', false);
INSERT INTO public.chat_messages (id, conversation_id, account_id, sender_uid) VALUES
  (public.fixture_uuid(41), public.fixture_uuid(31), public.fixture_uuid(1), public.fixture_uuid(11)),
  (public.fixture_uuid(42), public.fixture_uuid(32), public.fixture_uuid(1), public.fixture_uuid(11)),
  (public.fixture_uuid(43), public.fixture_uuid(32), public.fixture_uuid(2), public.fixture_uuid(13)),
  (public.fixture_uuid(44), public.fixture_uuid(33), public.fixture_uuid(3), public.fixture_uuid(14)),
  (public.fixture_uuid(45), public.fixture_uuid(31), public.fixture_uuid(1), public.fixture_uuid(12));
INSERT INTO storage.buckets VALUES ('chat-images'), ('chat-attachments');
INSERT INTO storage.files (id, bucket_id, name)
SELECT public.fixture_uuid(n + 10), 'chat-attachments',
       'attachments/' || conversation_id || '/' || id || '/fixture.txt'
FROM public.chat_messages,
LATERAL (SELECT right(id::text, 12)::integer AS n) AS fixture
WHERE id IN (
  public.fixture_uuid(41), public.fixture_uuid(42), public.fixture_uuid(43),
  public.fixture_uuid(44), public.fixture_uuid(45)
);
INSERT INTO public.chat_attachments (id, message_id, account_id, bucket, path)
SELECT public.fixture_uuid(n + 20), id, account_id, 'chat-attachments', public.fixture_uuid(n + 10)::text
FROM public.chat_messages,
LATERAL (SELECT right(id::text, 12)::integer AS n) AS fixture;
