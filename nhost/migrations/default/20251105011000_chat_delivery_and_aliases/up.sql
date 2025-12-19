-- 20251105011000_chat_delivery_and_aliases.sql
-- Adds delivery receipts tracking and per-user chat aliases.

-------------------------------------------------------------------------------
-- Delivery receipts
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.chat_delivery_receipts (
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  delivered_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_uid)
);

CREATE INDEX IF NOT EXISTS chat_delivery_receipts_message_idx
  ON public.chat_delivery_receipts (message_id);
CREATE INDEX IF NOT EXISTS chat_delivery_receipts_user_idx
  ON public.chat_delivery_receipts (user_uid);
CREATE INDEX IF NOT EXISTS chat_delivery_receipts_conversation_idx
  ON public.chat_delivery_receipts (conversation_id);

ALTER TABLE public.chat_delivery_receipts ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_delivery_receipts'
      AND policyname = 'delivery_receipts_select_member'
  ) THEN
    CREATE POLICY delivery_receipts_select_member
      ON public.chat_delivery_receipts
      FOR SELECT
      TO PUBLIC
      USING (
        fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1
          FROM public.chat_participants p
          JOIN public.chat_messages m
            ON m.id = chat_delivery_receipts.message_id
          WHERE p.conversation_id = m.conversation_id
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
      AND tablename = 'chat_delivery_receipts'
      AND policyname = 'delivery_receipts_insert_member'
  ) THEN
    CREATE POLICY delivery_receipts_insert_member
      ON public.chat_delivery_receipts
      FOR INSERT
      TO PUBLIC
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM public.chat_participants p
          JOIN public.chat_messages m
            ON m.id = chat_delivery_receipts.message_id
          WHERE p.conversation_id = m.conversation_id
            AND p.user_uid::text = public.request_uid_text()::text
            AND chat_delivery_receipts.user_uid = public.request_uid_text()::uuid
        )
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_delivery_receipts'
      AND policyname = 'delivery_receipts_update_member'
  ) THEN
    CREATE POLICY delivery_receipts_update_member
      ON public.chat_delivery_receipts
      FOR UPDATE
      TO PUBLIC
      USING (chat_delivery_receipts.user_uid::text = public.request_uid_text()::text);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_delivery_receipts'
      AND policyname = 'delivery_receipts_delete_member'
  ) THEN
    CREATE POLICY delivery_receipts_delete_member
      ON public.chat_delivery_receipts
      FOR DELETE
      TO PUBLIC
      USING (chat_delivery_receipts.user_uid::text = public.request_uid_text()::text);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.chat_mark_delivered(p_message_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authorized' USING errcode = '42501';
  END IF;

  INSERT INTO public.chat_delivery_receipts (message_id, conversation_id, user_uid, delivered_at)
  SELECT DISTINCT mid, m.conversation_id, v_uid, now()
  FROM unnest(coalesce(p_message_ids, ARRAY[]::uuid[])) AS mid
  JOIN public.chat_messages m ON m.id = mid
  WHERE m.sender_uid IS DISTINCT FROM v_uid
  ON CONFLICT (message_id, user_uid)
  DO UPDATE SET delivered_at = EXCLUDED.delivered_at;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_mark_delivered(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_mark_delivered(uuid[]) TO PUBLIC;

-------------------------------------------------------------------------------
-- Chat aliases
-------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.chat_aliases (
  owner_uid uuid NOT NULL,
  target_uid uuid NOT NULL,
  alias text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_uid, target_uid)
);

CREATE INDEX IF NOT EXISTS chat_aliases_target_idx
  ON public.chat_aliases (target_uid);

ALTER TABLE public.chat_aliases ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.tg_chat_aliases_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chat_aliases_set_updated_at ON public.chat_aliases;
CREATE TRIGGER chat_aliases_set_updated_at
BEFORE UPDATE ON public.chat_aliases
FOR EACH ROW
EXECUTE FUNCTION public.tg_chat_aliases_set_updated_at();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_aliases'
      AND policyname = 'chat_aliases_select_owner'
  ) THEN
    CREATE POLICY chat_aliases_select_owner
      ON public.chat_aliases
      FOR SELECT
      TO PUBLIC
      USING (owner_uid::text = public.request_uid_text()::text);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_aliases'
      AND policyname = 'chat_aliases_manage_owner'
  ) THEN
    CREATE POLICY chat_aliases_manage_owner
      ON public.chat_aliases
      FOR ALL
      TO PUBLIC
      USING (owner_uid::text = public.request_uid_text()::text)
      WITH CHECK (owner_uid::text = public.request_uid_text()::text);
  END IF;
END $$;
