-- 20251221090000_chat_typing.sql
-- Typing indicators for chat (Nhost).

SET search_path TO public;

CREATE TABLE IF NOT EXISTS public.chat_typing (
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  email text,
  typing boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_uid)
);

CREATE INDEX IF NOT EXISTS chat_typing_updated_at_idx
  ON public.chat_typing (updated_at);

ALTER TABLE public.chat_typing ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_typing'
      AND policyname = 'chat_typing_select_member'
  ) THEN
    CREATE POLICY chat_typing_select_member
      ON public.chat_typing
      FOR SELECT
      TO PUBLIC
      USING (
        fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1
          FROM public.chat_participants p
          WHERE p.conversation_id = chat_typing.conversation_id
            AND p.user_uid::text = public.request_uid_text()::text
        )
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_typing'
      AND policyname = 'chat_typing_manage_self'
  ) THEN
    CREATE POLICY chat_typing_manage_self
      ON public.chat_typing
      FOR ALL
      TO PUBLIC
      USING (
        user_uid::text = public.request_uid_text()::text
        AND EXISTS (
          SELECT 1
          FROM public.chat_participants p
          WHERE p.conversation_id = chat_typing.conversation_id
            AND p.user_uid::text = public.request_uid_text()::text
        )
      )
      WITH CHECK (
        user_uid::text = public.request_uid_text()::text
        AND EXISTS (
          SELECT 1
          FROM public.chat_participants p
          WHERE p.conversation_id = chat_typing.conversation_id
            AND p.user_uid::text = public.request_uid_text()::text
        )
      );
  END IF;
END $$;

DROP VIEW IF EXISTS public.v_chat_typing_active;
CREATE VIEW public.v_chat_typing_active AS
SELECT
  t.conversation_id,
  t.user_uid,
  t.email,
  t.updated_at
FROM public.chat_typing t
WHERE t.typing = true
  AND t.updated_at > (now() - interval '15 seconds');

REVOKE ALL ON TABLE public.v_chat_typing_active FROM PUBLIC;
GRANT SELECT ON TABLE public.v_chat_typing_active TO PUBLIC;
