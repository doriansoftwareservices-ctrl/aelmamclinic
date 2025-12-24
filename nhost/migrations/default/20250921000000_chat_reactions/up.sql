-- 20250921_chat_reactions.sql
-- جدول التفاعلات على الرسائل + سياسات RLS للمشاركين فقط + فهارس

-- 1) الجدول
-- ملاحظة: بافتراض أن chat_messages.id من نوع UUID.
-- إن كان نوعه TEXT لديك، غيّر النوع أدناه ليتطابق مع مخططك (وأزل FK أو عدّله).
CREATE TABLE IF NOT EXISTS public.chat_reactions (
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  user_uid  uuid NOT NULL, -- يطابق public.request_uid_text(); لا نضع FK على auth.users لتفادي صلاحيات عبر المخططات
  emoji     text NOT NULL CHECK (char_length(emoji) BETWEEN 1 AND 16),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_uid, emoji)
);
-- 2) تمكين RLS
ALTER TABLE public.chat_reactions ENABLE ROW LEVEL SECURITY;
-- 3) سياسة SELECT — أي مشارك في نفس المحادثة التي تنتمي لها الرسالة
DROP POLICY IF EXISTS "reactions select for participants" ON public.chat_reactions;
CREATE POLICY "reactions select for participants"
ON public.chat_reactions
FOR SELECT
TO PUBLIC
USING (
  EXISTS (
    SELECT 1
    FROM public.chat_messages m
    JOIN public.chat_participants p
      ON p.conversation_id = m.conversation_id
     AND p.user_uid = nullif(public.request_uid_text(), '')::uuid
    WHERE m.id = chat_reactions.message_id
  )
);
-- 4) سياسة INSERT — يجب أن يكون المُدخل مشاركًا، وباسمه فقط (user_uid = nullif(public.request_uid_text(), '')::uuid)
DROP POLICY IF EXISTS "reactions insert by participant self" ON public.chat_reactions;
CREATE POLICY "reactions insert by participant self"
ON public.chat_reactions
FOR INSERT
TO PUBLIC
WITH CHECK (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND EXISTS (
    SELECT 1
    FROM public.chat_messages m
    JOIN public.chat_participants p
      ON p.conversation_id = m.conversation_id
     AND p.user_uid = nullif(public.request_uid_text(), '')::uuid
    WHERE m.id = chat_reactions.message_id
  )
);
-- 5) سياسة DELETE — فقط صاحب التفاعل، ويجب أن يكون مشاركًا
DROP POLICY IF EXISTS "reactions delete by owner participant" ON public.chat_reactions;
CREATE POLICY "reactions delete by owner participant"
ON public.chat_reactions
FOR DELETE
TO PUBLIC
USING (
  user_uid = nullif(public.request_uid_text(), '')::uuid
  AND EXISTS (
    SELECT 1
    FROM public.chat_messages m
    JOIN public.chat_participants p
      ON p.conversation_id = m.conversation_id
     AND p.user_uid = nullif(public.request_uid_text(), '')::uuid
    WHERE m.id = chat_reactions.message_id
  )
);
-- لا نسمح بـ UPDATE (غير مطلوب وظيفيًا). إن رغبت لاحقًا، أضف سياسة مماثلة.

-- 6) فهارس/تحسينات
-- المفتاح الأساسي يكفي لاسترجاع حسب message_id، لكن نضيف فهرسًا مُركّزًا اختياريًا للاستخدامات التحليلية
CREATE INDEX IF NOT EXISTS chat_reactions_user_created_idx
  ON public.chat_reactions (user_uid, created_at DESC);
