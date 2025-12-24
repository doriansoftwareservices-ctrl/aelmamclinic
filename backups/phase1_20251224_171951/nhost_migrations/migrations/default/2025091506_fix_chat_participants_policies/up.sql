-- 2025091506_fix_chat_participants_policies.sql
-- إصلاح سياسات chat_participants لمنع recursion

-- تأكد أن RLS مفعّل
ALTER TABLE public.chat_participants ENABLE ROW LEVEL SECURITY;
-- احذف جميع السياسات الحالية على chat_participants (أياً كانت أسماؤها)
DO $$
DECLARE p text;
BEGIN
  FOR p IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'chat_participants'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.chat_participants', p);
  END LOOP;
END$$;
-- ✅ SELECT: اسمح للمستخدم برؤية صفوفه فقط (أو السوبر أدمن)
CREATE POLICY part_select_self_or_super
ON public.chat_participants
FOR SELECT
TO PUBLIC
USING ( user_uid = public.request_uid_text()::uuid OR fn_is_super_admin() );
-- ✅ INSERT: اسمح لمنشئ المحادثة بإضافة المشاركين (أو السوبر أدمن)
CREATE POLICY part_insert_by_creator_or_super
ON public.chat_participants
FOR INSERT
TO PUBLIC
WITH CHECK (
  fn_is_super_admin()
  OR EXISTS (
      SELECT 1
      FROM public.chat_conversations c
      WHERE c.id = chat_participants.conversation_id
        AND c.created_by = public.request_uid_text()::uuid
  )
);
-- (اختياري) UPDATE: عدّل صفك فقط (أو السوبر أدمن)
CREATE POLICY part_update_self_or_super
ON public.chat_participants
FOR UPDATE
TO PUBLIC
USING ( user_uid = public.request_uid_text()::uuid OR fn_is_super_admin() )
WITH CHECK ( user_uid = public.request_uid_text()::uuid OR fn_is_super_admin() );
-- (اختياري) DELETE: اسمح لمنشئ المحادثة بحذف المشاركين (أو السوبر أدمن)
CREATE POLICY part_delete_by_creator_or_super
ON public.chat_participants
FOR DELETE
TO PUBLIC
USING (
  fn_is_super_admin()
  OR EXISTS (
      SELECT 1
      FROM public.chat_conversations c
      WHERE c.id = chat_participants.conversation_id
        AND c.created_by = public.request_uid_text()::uuid
  )
);
