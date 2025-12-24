-- 2025091402_chat_policies.sql
-- سياسات RLS + دوال مساعدة لازمة (idempotent) بدون استخدام NEW. داخل السياسات
-- ومراعاة فروقات النوع uuid/text عبر التحويل إلى ::text

-- تأكد من وجود جدول super_admins قبل إنشاء الدوال التي تعتمد عليه
DO $$
BEGIN
  IF to_regclass('public.super_admins') IS NULL THEN
    CREATE TABLE IF NOT EXISTS public.super_admins (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      created_at timestamptz NOT NULL DEFAULT now(),
      account_id uuid,
      device_id text,
      local_id bigint,
      email text UNIQUE,
      user_uid uuid UNIQUE
    );
  END IF;
END$$;

-- تأكد من وجود request_uid_text قبل استخدامه داخل الدوال والسياسات
DO $$
BEGIN
  IF to_regproc('public.request_uid_text') IS NULL THEN
    CREATE FUNCTION public.request_uid_text()
    RETURNS text
    LANGUAGE sql
    STABLE
    AS $func$ SELECT null; $func$;
  END IF;
END$$;

-- ───────────────────────── Helper functions (idempotent) ─────────────────────────

-- هل المستخدم الحالي سوبر أدمن؟
CREATE OR REPLACE FUNCTION public.fn_is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
           SELECT 1
           FROM public.super_admins s
           WHERE s.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
         )
      OR EXISTS (
           SELECT 1
           FROM public.account_users au
           WHERE au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
             AND lower(au.role) = 'superadmin'
         );
$$;
-- آخر account_id للمستخدم الحالي (كنص)
CREATE OR REPLACE FUNCTION public.fn_my_latest_account_id()
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  acc text;
BEGIN
  SELECT au.account_id::text
    INTO acc
  FROM public.account_users au
  WHERE au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
  ORDER BY au.created_at DESC NULLS LAST
  LIMIT 1;

  RETURN acc;
END;
$$;
-- ───────────────────────── Enable RLS (idempotent) ─────────────────────────
ALTER TABLE public.chat_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_participants  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_reads         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_attachments   ENABLE ROW LEVEL SECURITY;
-- ───────────────────────── chat_conversations ─────────────────────────

-- SELECT: المشارك في المحادثة أو السوبر أدمن
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_conversations'
      AND policyname='conv_select_participant_or_super'
  ) THEN
    CREATE POLICY conv_select_participant_or_super
    ON public.chat_conversations
    FOR SELECT
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.chat_participants p
        WHERE p.conversation_id = chat_conversations.id
          AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- INSERT: المنشئ هو المستخدم الحالي + حارس account_id
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_conversations'
      AND policyname='conv_insert_creator_with_account_guard'
  ) THEN
    CREATE POLICY conv_insert_creator_with_account_guard
    ON public.chat_conversations
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      created_by::text = nullif(public.request_uid_text(), '')::uuid::text
      AND (
        fn_is_super_admin() = true
        OR account_id IS NULL
        OR EXISTS (
          SELECT 1
          FROM public.account_users au
          WHERE au.account_id = chat_conversations.account_id
            AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
            AND coalesce(au.disabled, false) = false
        )
      )
    );
  END IF;
END$$;
-- UPDATE: صاحب الإنشاء أو السوبر + ثبات حارس الحساب
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_conversations'
      AND policyname='conv_update_creator_or_super'
  ) THEN
    CREATE POLICY conv_update_creator_or_super
    ON public.chat_conversations
    FOR UPDATE
    TO PUBLIC
    USING (
      fn_is_super_admin() = true OR created_by::text = nullif(public.request_uid_text(), '')::uuid::text
    )
    WITH CHECK (
      fn_is_super_admin() = true
      OR account_id IS NULL
      OR EXISTS (
        SELECT 1
        FROM public.account_users au
        WHERE au.account_id = chat_conversations.account_id
          AND au.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
          AND coalesce(au.disabled, false) = false
      )
    );
  END IF;
END$$;
-- ───────────────────────── chat_participants ─────────────────────────

-- SELECT: أي مستخدم مشارك في نفس المحادثة أو سوبر
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_participants'
      AND policyname='parts_select_if_conversation_member_or_super'
  ) THEN
    CREATE POLICY parts_select_if_conversation_member_or_super
    ON public.chat_participants
    FOR SELECT
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.chat_participants p2
        WHERE p2.conversation_id = chat_participants.conversation_id
          AND p2.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- INSERT: منشئ المحادثة أو السوبر فقط يضيف مشاركين
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_participants'
      AND policyname='parts_insert_by_conv_creator_or_super'
  ) THEN
    CREATE POLICY parts_insert_by_conv_creator_or_super
    ON public.chat_participants
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.chat_conversations c
        WHERE c.id = chat_participants.conversation_id
          AND c.created_by::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- UPDATE/DELETE: منشئ المحادثة أو السوبر
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_participants'
      AND policyname='parts_update_by_conv_creator_or_super'
  ) THEN
    CREATE POLICY parts_update_by_conv_creator_or_super
    ON public.chat_participants
    FOR UPDATE
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.chat_conversations c
        WHERE c.id = chat_participants.conversation_id
          AND c.created_by::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    )
    WITH CHECK (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.chat_conversations c
        WHERE c.id = chat_participants.conversation_id
          AND c.created_by::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_participants'
      AND policyname='parts_delete_by_conv_creator_or_super'
  ) THEN
    CREATE POLICY parts_delete_by_conv_creator_or_super
    ON public.chat_participants
    FOR DELETE
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.chat_conversations c
        WHERE c.id = chat_participants.conversation_id
          AND c.created_by::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- ───────────────────────── chat_messages ─────────────────────────

-- SELECT: المشارك أو السوبر
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_messages'
      AND policyname='msgs_select_if_participant_or_super'
  ) THEN
    CREATE POLICY msgs_select_if_participant_or_super
    ON public.chat_messages
    FOR SELECT
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1 FROM public.chat_participants p
        WHERE p.conversation_id = chat_messages.conversation_id
          AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- INSERT: المرسل هو المستخدم الحالي + عضو بالمحادثة
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_messages'
      AND policyname='msgs_insert_sender_is_self_and_member'
  ) THEN
    CREATE POLICY msgs_insert_sender_is_self_and_member
    ON public.chat_messages
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      sender_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      AND EXISTS (
        SELECT 1 FROM public.chat_participants p
        WHERE p.conversation_id = chat_messages.conversation_id
          AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- UPDATE/DELETE: صاحب الرسالة أو السوبر
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_messages'
      AND policyname='msgs_update_owner_or_super'
  ) THEN
    CREATE POLICY msgs_update_owner_or_super
    ON public.chat_messages
    FOR UPDATE
    TO PUBLIC
    USING (fn_is_super_admin() = true OR sender_uid::text = nullif(public.request_uid_text(), '')::uuid::text)
    WITH CHECK (fn_is_super_admin() = true OR sender_uid::text = nullif(public.request_uid_text(), '')::uuid::text);
  END IF;
END$$;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_messages'
      AND policyname='msgs_delete_owner_or_super'
  ) THEN
    CREATE POLICY msgs_delete_owner_or_super
    ON public.chat_messages
    FOR DELETE
    TO PUBLIC
    USING (fn_is_super_admin() = true OR sender_uid::text = nullif(public.request_uid_text(), '')::uuid::text);
  END IF;
END$$;
-- ───────────────────────── chat_reads ─────────────────────────

-- SELECT: صفوف قراءتي فقط وفي محادثات أنا عضو فيها (أو سوبر)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_reads'
      AND policyname='reads_select_self_or_super_if_member'
  ) THEN
    CREATE POLICY reads_select_self_or_super_if_member
    ON public.chat_reads
    FOR SELECT
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR (
        user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
        AND EXISTS (
          SELECT 1 FROM public.chat_participants p
          WHERE p.conversation_id = chat_reads.conversation_id
            AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
        )
      )
    );
  END IF;
END$$;
-- INSERT: أكتب فقط لقراءتي وفي محادثة أنا عضو فيها
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_reads'
      AND policyname='reads_insert_self_if_member'
  ) THEN
    CREATE POLICY reads_insert_self_if_member
    ON public.chat_reads
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      AND EXISTS (
        SELECT 1 FROM public.chat_participants p
        WHERE p.conversation_id = chat_reads.conversation_id
          AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- UPDATE: أحدّث فقط صفّي وفي محادثة أنا عضو فيها (أو سوبر)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_reads'
      AND policyname='reads_update_self_or_super_if_member'
  ) THEN
    CREATE POLICY reads_update_self_or_super_if_member
    ON public.chat_reads
    FOR UPDATE
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR (
        user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
        AND EXISTS (
          SELECT 1 FROM public.chat_participants p
          WHERE p.conversation_id = chat_reads.conversation_id
            AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
        )
      )
    )
    WITH CHECK (
      fn_is_super_admin() = true
      OR (
        user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
        AND EXISTS (
          SELECT 1 FROM public.chat_participants p
          WHERE p.conversation_id = chat_reads.conversation_id
            AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
        )
      )
    );
  END IF;
END$$;
-- ───────────────────────── chat_attachments (DB) ─────────────────────────

-- SELECT: المشارك أو السوبر
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_attachments'
      AND policyname='atts_select_if_participant_or_super'
  ) THEN
    CREATE POLICY atts_select_if_participant_or_super
    ON public.chat_attachments
    FOR SELECT
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1
        FROM public.chat_messages m
        JOIN public.chat_participants p
          ON p.conversation_id = m.conversation_id
        WHERE m.id = chat_attachments.message_id
          AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- INSERT: مشارك في المحادثة المرتبطة بالرسالة (أو سوبر)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_attachments'
      AND policyname='atts_insert_if_participant_or_super'
  ) THEN
    CREATE POLICY atts_insert_if_participant_or_super
    ON public.chat_attachments
    FOR INSERT
    TO PUBLIC
    WITH CHECK (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1
        FROM public.chat_messages m
        JOIN public.chat_participants p
          ON p.conversation_id = m.conversation_id
        WHERE m.id = chat_attachments.message_id
          AND p.user_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
-- DELETE: صاحب الرسالة أو السوبر
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='chat_attachments'
      AND policyname='atts_delete_owner_message_or_super'
  ) THEN
    CREATE POLICY atts_delete_owner_message_or_super
    ON public.chat_attachments
    FOR DELETE
    TO PUBLIC
    USING (
      fn_is_super_admin() = true
      OR EXISTS (
        SELECT 1
        FROM public.chat_messages m
        WHERE m.id = chat_attachments.message_id
          AND m.sender_uid::text = nullif(public.request_uid_text(), '')::uuid::text
      )
    );
  END IF;
END$$;
