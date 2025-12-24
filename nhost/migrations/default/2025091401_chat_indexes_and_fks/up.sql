-- 20250914_chat_indexes_and_fks.sql
-- فهارس + علاقات (FK) لجدول الدردشة.
-- ملاحظة مهمّة: أضفنا خطوة تنظيف قبل إضافة FK الخاص بـ chat_conversations.account_id → clinics.id
-- لتفادي بيانات قديمة لا يقابلها صف في clinics.

-- ───────────────────────────── فهارس عامة ─────────────────────────────

DO $$
BEGIN
  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    -- رسائل المحادثات: تسلسل حسب الوقت داخل محادثة
    CREATE INDEX IF NOT EXISTS idx_chat_messages_conv_created_at
      ON public.chat_messages (conversation_id, created_at);
    -- للمساعدة في الاستدعاءات اللحظية
    CREATE INDEX IF NOT EXISTS idx_chat_messages_conv_id
      ON public.chat_messages (conversation_id, id);
    -- حقل النوع/الحذف للاستعلام عن آخر رسالة غير محذوفة
    CREATE INDEX IF NOT EXISTS idx_chat_messages_kind_deleted
      ON public.chat_messages (kind, deleted);
    -- فهرس للمرسل (اختياري لكن مفيد)
    CREATE INDEX IF NOT EXISTS idx_chat_messages_sender
      ON public.chat_messages (sender_uid);
  END IF;

  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    -- آخر نشاط للمحادثة
    CREATE INDEX IF NOT EXISTS idx_chat_conversations_last_msg_at
      ON public.chat_conversations (last_msg_at DESC);
    -- حساب المحادثة (لجلب اسم العيادة مثلاً)
    CREATE INDEX IF NOT EXISTS idx_chat_conversations_account
      ON public.chat_conversations (account_id);
  END IF;

  IF to_regclass('public.chat_participants') IS NOT NULL THEN
    -- ربط المشاركين بالمحادثة
    CREATE INDEX IF NOT EXISTS idx_chat_participants_conv_uid
      ON public.chat_participants (conversation_id, user_uid);
  END IF;

  IF to_regclass('public.chat_reads') IS NOT NULL THEN
    -- حالة القراءة لكل مستخدم داخل محادثة
    CREATE INDEX IF NOT EXISTS idx_chat_reads_conv_uid
      ON public.chat_reads (conversation_id, user_uid);
  END IF;

  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    -- مرفقات الرسالة
    CREATE INDEX IF NOT EXISTS idx_chat_attachments_message
      ON public.chat_attachments (message_id);
  END IF;
END$$;
-- ───────────────────────────── علاقات (FK) مع حراسة ─────────────────────────────

-- chat_attachments.message_id → chat_messages.id
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'chat_attachments')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_chat_attachments_message') THEN

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='chat_attachments' AND column_name='message_id')
       AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='chat_messages') THEN

      ALTER TABLE public.chat_attachments
        ADD CONSTRAINT fk_chat_attachments_message
        FOREIGN KEY (message_id)
        REFERENCES public.chat_messages(id)
        ON DELETE CASCADE;
    END IF;
  END IF;
END$$;
-- chat_messages.conversation_id → chat_conversations.id
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'chat_messages')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_chat_messages_conversation') THEN

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='chat_messages' AND column_name='conversation_id')
       AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='chat_conversations') THEN

      ALTER TABLE public.chat_messages
        ADD CONSTRAINT fk_chat_messages_conversation
        FOREIGN KEY (conversation_id)
        REFERENCES public.chat_conversations(id)
        ON DELETE CASCADE;
    END IF;
  END IF;
END$$;
-- chat_participants.conversation_id → chat_conversations.id
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'chat_participants')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_chat_participants_conversation') THEN

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='chat_participants' AND column_name='conversation_id')
       AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='chat_conversations') THEN

      ALTER TABLE public.chat_participants
        ADD CONSTRAINT fk_chat_participants_conversation
        FOREIGN KEY (conversation_id)
        REFERENCES public.chat_conversations(id)
        ON DELETE CASCADE;
    END IF;
  END IF;
END$$;
-- chat_reads.conversation_id → chat_conversations.id
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'chat_reads')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_chat_reads_conversation') THEN

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='chat_reads' AND column_name='conversation_id')
       AND EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema='public' AND table_name='chat_conversations') THEN

      ALTER TABLE public.chat_reads
        ADD CONSTRAINT fk_chat_reads_conversation
        FOREIGN KEY (conversation_id)
        REFERENCES public.chat_conversations(id)
        ON DELETE CASCADE;
    END IF;
  END IF;
END$$;
-- chat_conversations.account_id → clinics.id (إن وجد جدول clinics)
-- ⚠️ يتضمن تنظيف بيانات قديمة تحول دون إضافة القيد
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='accounts')
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='fk_chat_conversations_account') THEN

    -- تأكد من وجود العمود أولًا
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='chat_conversations' AND column_name='account_id') THEN

      -- تنظيف: أي account_id لا يقابله صف في clinics → NULL لتفادي فشل إضافة الـ FK
      UPDATE public.chat_conversations c
      SET account_id = NULL
      WHERE account_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.accounts x WHERE x.id = c.account_id
        );

      -- الآن أضِف الـ FK بأمان
      ALTER TABLE public.chat_conversations
        ADD CONSTRAINT fk_chat_conversations_account
        FOREIGN KEY (account_id)
        REFERENCES public.accounts(id)
        ON DELETE SET NULL;
    END IF;
  END IF;
END$$;
