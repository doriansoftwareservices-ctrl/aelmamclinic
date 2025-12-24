-- 20250920_chat_indexes.sql
-- فهارس وتحسينات الأداء لجداول الدردشة

-- ملاحظة: امتداد pg_trgm يجب تمكينه يدوياً من لوحة تحكم Supabase (Database → Extensions)

DO $$
BEGIN
  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    -- أعمدة إضافية لدعم الردود والإشارة للرسائل
    ALTER TABLE public.chat_messages
      ADD COLUMN IF NOT EXISTS reply_to_message_id uuid,
      ADD COLUMN IF NOT EXISTS reply_to_snippet text,
      ADD COLUMN IF NOT EXISTS mentions jsonb;

    -- فهارس chat_messages الأساسية
    CREATE INDEX IF NOT EXISTS chat_messages_conv_created_idx
      ON public.chat_messages (conversation_id, created_at);
    CREATE INDEX IF NOT EXISTS chat_messages_created_idx
      ON public.chat_messages (created_at);
    CREATE INDEX IF NOT EXISTS chat_messages_reply_to_idx
      ON public.chat_messages (reply_to_message_id);

    -- فهرس trigram اختياري (يُنشأ فقط إذا كان امتداد pg_trgm متاحاً)
    IF EXISTS (SELECT 1 FROM pg_opclass WHERE opcname = 'gin_trgm_ops') THEN
      IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public' AND indexname = 'chat_messages_body_trgm_idx'
      ) THEN
        EXECUTE $sql$
          CREATE INDEX chat_messages_body_trgm_idx
            ON public.chat_messages
            USING gin ((coalesce(body, '')) gin_trgm_ops)
        $sql$;
      END IF;
    ELSE
      RAISE NOTICE 'skip chat_messages_body_trgm_idx: pg_trgm is not enabled';
    END IF;
  ELSE
    RAISE NOTICE 'skip chat_messages indexes: table does not exist';
  END IF;

  IF to_regclass('public.chat_participants') IS NOT NULL THEN
    -- فهارس chat_participants
    CREATE INDEX IF NOT EXISTS chat_participants_conv_user_idx
      ON public.chat_participants (conversation_id, user_uid);
    CREATE INDEX IF NOT EXISTS chat_participants_user_idx
      ON public.chat_participants (user_uid);
  END IF;

  IF to_regclass('public.chat_reads') IS NOT NULL THEN
    -- فهارس chat_reads
    CREATE INDEX IF NOT EXISTS chat_reads_conv_user_idx
      ON public.chat_reads (conversation_id, user_uid);
    CREATE INDEX IF NOT EXISTS chat_reads_user_idx
      ON public.chat_reads (user_uid);
  END IF;

  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    -- فهرس زمني للمحادثات
    CREATE INDEX IF NOT EXISTS chat_conversations_last_msg_at_idx
      ON public.chat_conversations (last_msg_at);
  END IF;

  -- فهارس مرفقات الدردشة (إذا كان الجدول موجوداً)
  IF to_regclass('public.chat_attachments') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS chat_attachments_msg_idx
      ON public.chat_attachments (message_id);
    CREATE INDEX IF NOT EXISTS chat_attachments_bucket_path_idx
      ON public.chat_attachments (bucket, path);
  END IF;
END;
$$;
