DO $do$
BEGIN
  -- 1) columns
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    ALTER TABLE public.chat_conversations
      ADD COLUMN IF NOT EXISTS account_id uuid;
  ELSE
    RAISE NOTICE 'skip: chat_conversations missing';
  END IF;

  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    ALTER TABLE public.chat_messages
      ADD COLUMN IF NOT EXISTS account_id uuid,
      ADD COLUMN IF NOT EXISTS device_id  text,
      ADD COLUMN IF NOT EXISTS local_id   bigint;
  ELSE
    RAISE NOTICE 'skip: chat_messages missing';
  END IF;

  IF to_regclass('public.account_users') IS NOT NULL THEN
    ALTER TABLE public.account_users
      ADD COLUMN IF NOT EXISTS device_id text;
  END IF;

  -- 2) backfill
  IF to_regclass('public.chat_messages') IS NOT NULL AND to_regclass('public.chat_conversations') IS NOT NULL THEN
    UPDATE public.chat_messages m
    SET account_id = c.account_id
    FROM public.chat_conversations c
    WHERE m.conversation_id = c.id
      AND m.account_id IS NULL;
  END IF;

  -- 3) comments
  IF to_regclass('public.chat_messages') IS NOT NULL THEN
    COMMENT ON COLUMN public.chat_messages.account_id IS
      'حقل اختياري لتجميع الرسائل حسب الحساب (clinic/account). يُستخدم ضمن triplet مع device_id/local_id.';
    COMMENT ON COLUMN public.chat_messages.device_id IS
      'مُعرّف الجهاز/العميل المرسل (اختياري). جزء من triplet لمطابقة الرسائل محليًا.';
    COMMENT ON COLUMN public.chat_messages.local_id IS
      'مُعرّف محلي متزايد (BIGINT) داخل الجهاز/الجلسة، يُستخدم لتجنّب التكرار أثناء الإرسال.';
  END IF;

  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    COMMENT ON COLUMN public.chat_conversations.account_id IS
      'معرّف الحساب (clinic/account) المرتبطة به المحادثة.';
  END IF;
END
$do$;
