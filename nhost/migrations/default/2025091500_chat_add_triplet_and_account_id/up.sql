-- 20250914_chat_add_triplet_and_account_id.sql
-- إضافة أعمدة triplet إلى chat_messages + ضمان وجود account_id في chat_conversations
-- وتهيئة مبدئية للقيم.

-- ملاحظات:
-- - نستخدم ALTER TABLE ... ADD COLUMN IF NOT EXISTS لضمان idempotency.
-- - لا نضيف فهارس/قيود هنا (ستكون في ملف: 20250914_chat_indexes_and_fks.sql).
-- - نوع account_id = UUID ليتماشى مع باقي الجداول (account_users/clinics).

-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ 1) أعمدة جديدة                                                              │
-- ╰──────────────────────────────────────────────────────────────────────────────╯

-- في المحادثات: تأكد من وجود account_id
ALTER TABLE IF EXISTS public.chat_conversations
  ADD COLUMN IF NOT EXISTS account_id uuid;
-- في الرسائل: أضف triplet (account_id/device_id/local_id)
ALTER TABLE IF EXISTS public.chat_messages
  ADD COLUMN IF NOT EXISTS account_id uuid,
  ADD COLUMN IF NOT EXISTS device_id  text,
  ADD COLUMN IF NOT EXISTS local_id   bigint;
-- اختياري: تخزين device_id الأحدث للمستخدم على مستوى account_users (تستخدمه الخدمة)
ALTER TABLE IF EXISTS public.account_users
  ADD COLUMN IF NOT EXISTS device_id text;
-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ 2) تهيئة مبدئية (Backfill)                                                 │
-- ╰──────────────────────────────────────────────────────────────────────────────╯

-- انسخ account_id من المحادثة إلى الرسالة حيثما كان مفقودًا.
-- يفترض أن chat_conversations.account_id من النوع uuid.
UPDATE public.chat_messages m
SET account_id = c.account_id
FROM public.chat_conversations c
WHERE m.conversation_id = c.id
  AND m.account_id IS NULL;
-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ 3) تعليقات توضيحية                                                         │
-- ╰──────────────────────────────────────────────────────────────────────────────╯

COMMENT ON COLUMN public.chat_messages.account_id IS
  'حقل اختياري لتجميع الرسائل حسب الحساب (clinic/account). يُستخدم ضمن triplet مع device_id/local_id.';
COMMENT ON COLUMN public.chat_messages.device_id IS
  'مُعرّف الجهاز/العميل المرسل (اختياري). جزء من triplet لمطابقة الرسائل محليًا.';
COMMENT ON COLUMN public.chat_messages.local_id IS
  'مُعرّف محلي متزايد (BIGINT) داخل الجهاز/الجلسة، يُستخدم لتجنّب التكرار أثناء الإرسال.';
COMMENT ON COLUMN public.chat_conversations.account_id IS
  'معرّف الحساب (clinic/account) المرتبطة به المحادثة.';
-- انتهى;
