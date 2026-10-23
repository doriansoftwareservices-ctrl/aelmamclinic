-- Private synthetic PostgreSQL fixture. Never use against an application DB.
-- The runner creates a fresh cluster and loads the listed production migrations.
CREATE SCHEMA auth;
CREATE TABLE public.elmam_chat_acl_fixture_marker (value text PRIMARY KEY);
INSERT INTO public.elmam_chat_acl_fixture_marker
VALUES ('local_chat_acl_scope_20261019');
CREATE FUNCTION public.fixture_uuid(value integer) RETURNS uuid
LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-4000-8000-' || lpad(value::text, 12, '0'))::uuid
$$;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY, disabled boolean DEFAULT false, email text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.accounts (
  id uuid PRIMARY KEY, name text, frozen boolean DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.account_users (
  account_id uuid REFERENCES public.accounts, user_uid uuid REFERENCES auth.users,
  role text, disabled boolean DEFAULT false,created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, user_uid)
);
CREATE TABLE public.super_admins (
  user_uid uuid PRIMARY KEY REFERENCES auth.users, disabled boolean DEFAULT false
);
CREATE TABLE public.account_feature_permissions (
  account_id uuid,user_uid uuid,allow_all boolean,allowed_features text[],
  can_create boolean,can_update boolean,can_delete boolean
);
-- Exact legacy RPC result projection; unrelated RPCs are not installed here.
CREATE VIEW public.v_rpc_result AS SELECT NULL::boolean AS ok,NULL::text AS error,
  NULL::uuid AS account_id,NULL::uuid AS user_uid,NULL::uuid AS owner_uid,
  NULL::text AS role,NULL::boolean AS frozen,NULL::boolean AS disabled WHERE false;
CREATE VIEW public.v_uuid_result AS SELECT NULL::uuid AS id WHERE false;
CREATE TABLE public.chat_support_agents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_uid uuid UNIQUE REFERENCES auth.users,
  display_name text NOT NULL DEFAULT 'Fixture support',is_active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),created_by uuid
);
CREATE TABLE public.chat_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),message_id uuid,account_id uuid,
  bucket text,path text,mime_type text,size_bytes bigint,width integer,height integer,
  created_at timestamptz NOT NULL DEFAULT now(),is_deleted boolean NOT NULL DEFAULT false
);
-- Reuse the real existing chat table definitions, including composite FKs.
\ir ../nhost/migrations/default/20260118150000_create_missing_chat_and_profiles_tables/up.sql
\ir ../nhost/migrations/default/20260122190000_chat_client_msg_id/up.sql
-- Full reaction columns/composite identity from restore_core_domain (20250913).
CREATE TABLE public.chat_reactions (
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,emoji text NOT NULL CHECK (char_length(emoji) BETWEEN 1 AND 16),
  created_at timestamptz NOT NULL DEFAULT now(),deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,device_id text,local_id bigint,
  PRIMARY KEY(message_id,user_uid,emoji),
  FOREIGN KEY(account_id,user_uid) REFERENCES public.account_users(account_id,user_uid)
);
\ir ../nhost/migrations/default/20250921000000_chat_reactions/up.sql
ALTER TABLE public.chat_conversations
  ADD COLUMN is_frozen boolean NOT NULL DEFAULT false,
  ADD COLUMN admins_only boolean NOT NULL DEFAULT false;
ALTER TABLE public.chat_participants
  ADD COLUMN is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN deleted_at timestamptz;
ALTER TABLE public.chat_reads
  ADD COLUMN last_delivered_message_id uuid REFERENCES public.chat_messages,
  ADD COLUMN last_delivered_at timestamptz;
CREATE TABLE public.chat_delivery_receipts (
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,delivered_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(message_id,user_uid)
);
CREATE TABLE public.chat_typing (
  account_id uuid REFERENCES public.accounts, conversation_id uuid REFERENCES public.chat_conversations,
  user_uid uuid REFERENCES auth.users, email text,
  typing boolean NOT NULL DEFAULT false, updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id,user_uid)
);
-- Existing views required by the real final preview migration.
CREATE VIEW public.v_chat_reads_for_me AS
SELECT conversation_id,last_read_message_id,last_read_at,
       last_delivered_message_id,last_delivered_at
FROM public.chat_reads
WHERE user_uid = nullif(public.request_uid_text(), '')::uuid;
\ir ../nhost/migrations/default/20260222193000_secure_chat_views_and_clinics/up.sql
\ir ../nhost/migrations/default/20260223013000_secure_chat_views_membership/up.sql
\ir ../nhost/migrations/default/20260303100000_support_chat_ratings/up.sql

INSERT INTO public.accounts (id,name) SELECT public.fixture_uuid(n),'Fixture clinic '||n
FROM generate_series(1,3) n;
INSERT INTO auth.users (id,disabled,email)
SELECT public.fixture_uuid(n),n=17,'fixture-'||n||'@example.invalid'
FROM generate_series(11,26) n;
INSERT INTO public.account_users(account_id,user_uid,role,disabled) VALUES
  (public.fixture_uuid(1),public.fixture_uuid(11),'owner',false),
  (public.fixture_uuid(1),public.fixture_uuid(12),'employee',false),
  (public.fixture_uuid(2),public.fixture_uuid(13),'owner',false),
  (public.fixture_uuid(3),public.fixture_uuid(14),'owner',false),
  (public.fixture_uuid(1),public.fixture_uuid(17),'owner',false),
  (public.fixture_uuid(1),public.fixture_uuid(18),'owner',false),
  (public.fixture_uuid(2),public.fixture_uuid(19),'owner',true),
  (public.fixture_uuid(2),public.fixture_uuid(22),'employee',false),
  (public.fixture_uuid(1),public.fixture_uuid(23),'employee',false),
  (public.fixture_uuid(1),public.fixture_uuid(24),'employee',false);
INSERT INTO public.super_admins VALUES
  (public.fixture_uuid(15),false),(public.fixture_uuid(20),true),
  (public.fixture_uuid(21),false);
INSERT INTO public.chat_conversations(id,account_id,created_by,title,is_group) VALUES
  (public.fixture_uuid(31),public.fixture_uuid(1),public.fixture_uuid(11),'Tenant fixture',true),
  (public.fixture_uuid(32),NULL,public.fixture_uuid(11),'Global fixture',false),
  (public.fixture_uuid(33),NULL,public.fixture_uuid(14),'Other global fixture',false),
  (public.fixture_uuid(34),public.fixture_uuid(1),public.fixture_uuid(11),'Unjoined creator fixture',true),
  (public.fixture_uuid(35),public.fixture_uuid(1),public.fixture_uuid(11),'Assigned support fixture',false);
INSERT INTO public.chat_participants(conversation_id,user_uid,account_id,role,is_deleted) VALUES
  (public.fixture_uuid(31),public.fixture_uuid(11),public.fixture_uuid(1),'owner',false),
  (public.fixture_uuid(31),public.fixture_uuid(12),public.fixture_uuid(1),'member',false),
  (public.fixture_uuid(31),public.fixture_uuid(13),public.fixture_uuid(2),'owner',false),
  (public.fixture_uuid(31),public.fixture_uuid(17),public.fixture_uuid(1),'owner',false),
  (public.fixture_uuid(31),public.fixture_uuid(23),public.fixture_uuid(1),'admin',false),
  (public.fixture_uuid(31),public.fixture_uuid(24),public.fixture_uuid(1),'member',true),
  (public.fixture_uuid(32),public.fixture_uuid(11),NULL,'owner',false),
  (public.fixture_uuid(32),public.fixture_uuid(13),NULL,'owner',false),
  (public.fixture_uuid(32),public.fixture_uuid(12),NULL,'member',false),
  (public.fixture_uuid(32),public.fixture_uuid(16),NULL,'owner',false),
  (public.fixture_uuid(32),public.fixture_uuid(18),NULL,'owner',true),
  (public.fixture_uuid(32),public.fixture_uuid(19),NULL,'owner',false),
  (public.fixture_uuid(32),public.fixture_uuid(20),NULL,'admin',false),
  (public.fixture_uuid(32),public.fixture_uuid(22),NULL,'member',false),
  (public.fixture_uuid(33),public.fixture_uuid(14),NULL,'owner',false),
  (public.fixture_uuid(35),public.fixture_uuid(11),public.fixture_uuid(1),'owner',false),
  (public.fixture_uuid(35),public.fixture_uuid(25),NULL,'admin',false),
  (public.fixture_uuid(35),public.fixture_uuid(26),NULL,'admin',false),
  (public.fixture_uuid(31),public.fixture_uuid(25),NULL,'admin',false);
INSERT INTO public.chat_support_agents(user_uid,is_active)
VALUES (public.fixture_uuid(25),true),(public.fixture_uuid(26),false);
INSERT INTO public.chat_messages(id,conversation_id,account_id,sender_uid,body) VALUES
  (public.fixture_uuid(41),public.fixture_uuid(31),public.fixture_uuid(1),public.fixture_uuid(11),'Tenant private fixture'),
  (public.fixture_uuid(42),public.fixture_uuid(32),NULL,public.fixture_uuid(11),'Global private fixture'),
  (public.fixture_uuid(43),public.fixture_uuid(33),NULL,public.fixture_uuid(14),'Other private fixture'),
  (public.fixture_uuid(44),public.fixture_uuid(35),public.fixture_uuid(1),public.fixture_uuid(11),'Support private fixture'),
  (public.fixture_uuid(45),public.fixture_uuid(35),NULL,public.fixture_uuid(25),'Support sender fixture');
INSERT INTO public.chat_attachments(id,message_id,account_id,bucket,path,mime_type,size_bytes) VALUES
  (public.fixture_uuid(61),public.fixture_uuid(41),public.fixture_uuid(1),'chat-attachments',public.fixture_uuid(51)::text,'text/plain',12);
INSERT INTO public.chat_reads(account_id,conversation_id,user_uid,last_read_message_id,last_read_at)
SELECT account_id,conversation_id,user_uid,NULL,now() FROM public.chat_participants;
INSERT INTO public.chat_delivery_receipts(message_id,conversation_id,user_uid)
VALUES (public.fixture_uuid(41),public.fixture_uuid(31),public.fixture_uuid(12));
INSERT INTO public.chat_typing(account_id,conversation_id,user_uid,email,typing)
SELECT account_id,conversation_id,user_uid,'typing@example.invalid',true FROM public.chat_participants;

-- A real non-owner, non-superuser role for SQL execution/trigger checks.
CREATE ROLE elmam_chat_acl_client NOLOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT;
GRANT USAGE ON SCHEMA public,auth TO elmam_chat_acl_client;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.chat_conversations,
  public.chat_participants,public.chat_messages,public.chat_reads,public.chat_typing
TO elmam_chat_acl_client;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.chat_delivery_receipts TO elmam_chat_acl_client;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.chat_reactions TO elmam_chat_acl_client;
GRANT SELECT ON public.accounts,public.account_users,public.super_admins,auth.users
TO elmam_chat_acl_client;
