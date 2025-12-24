-- 20250914_fn_sign_chat_attachment.sql
-- وظيفة: توقيع رابط مرفق دردشة بعد التحقق من صلاحية المستخدم للوصول إليه.

SET search_path TO public;
-- احذف الدالة إن وُجدت مسبقًا
DROP FUNCTION IF EXISTS public.fn_sign_chat_attachment(text, text, integer);
-- ملاحظة:
-- تعتمد هذه الدالة على جداول:
--   chat_attachments(message_id, bucket, path)
--   chat_messages(id, conversation_id)
--   chat_participants(conversation_id, user_uid)
-- وتستخدم دالة Supabase Storage:
--   storage.create_signed_url(bucket text, path text, expires_in int)
-- إن كانت نسخة المنصة لا توفّر create_signed_url كدالة SQL، يمكنك الاعتماد
-- على Edge Function بديل (chat/sign-attachment) كما هو مستخدم بالتطبيق.

CREATE OR REPLACE FUNCTION public.fn_sign_chat_attachment(
  p_bucket     text,
  p_path       text,
  p_expires_in integer DEFAULT 900  -- ثواني (15 دقيقة افتراضيًا)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id    uuid;
  v_conversation  uuid;
  v_has_access    boolean;
  v_signed_url    text;
BEGIN
  -- تحقق أن هذا المسار مسجّل كمرفق دردشة
  SELECT a.message_id
    INTO v_message_id
  FROM public.chat_attachments a
  WHERE a.bucket = p_bucket
    AND a.path   = p_path
  LIMIT 1;

  IF v_message_id IS NULL THEN
    RAISE EXCEPTION 'Attachment not found' USING ERRCODE = 'no_data_found';
  END IF;

  -- اجلب محادثته
  SELECT m.conversation_id
    INTO v_conversation
  FROM public.chat_messages m
  WHERE m.id = v_message_id;

  IF v_conversation IS NULL THEN
    RAISE EXCEPTION 'Message not found for attachment' USING ERRCODE = 'no_data_found';
  END IF;

  -- تحقّق أن المستخدم الحالي عضو في المحادثة
  SELECT EXISTS(
    SELECT 1
    FROM public.chat_participants p
    WHERE p.conversation_id = v_conversation
      AND p.user_uid = public.request_uid_text()::uuid
  ) INTO v_has_access;

  IF NOT v_has_access THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- أنشئ الرابط الموقّع عبر دالة التخزين
  -- ملاحظة: بعض منصّات Supabase توفّر storage.create_signed_url كدالة SQL.
  -- إن لم تكن متاحة في بيئتك، استخدم Edge Function بديل.
  BEGIN
    v_signed_url := storage.create_signed_url(p_bucket, p_path, p_expires_in);
  EXCEPTION WHEN undefined_function THEN
    -- لو لم تتوفر الدالة في هذه البيئة، نرمي خطأ واضحًا.
    RAISE EXCEPTION
      'storage.create_signed_url is not available on this instance. Use the Edge Function instead.'
      USING ERRCODE = 'feature_not_supported';
  END;

  RETURN jsonb_build_object(
    'signedUrl', v_signed_url,
    'url',       v_signed_url  -- للتوافق مع بعض العملاء
  );
END;
$$;
-- الأذونات: اسمح بالتنفيذ للمستخدمين الموثّقين وامنع المجهولين
REVOKE ALL ON FUNCTION public.fn_sign_chat_attachment(text, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_sign_chat_attachment(text, text, integer) TO PUBLIC;
-- بإمكانك منحها لـ service_role إن رغبت:
-- GRANT EXECUTE ON FUNCTION public.fn_sign_chat_attachment(text, text, integer) TO public;

COMMENT ON FUNCTION public.fn_sign_chat_attachment(text, text, integer)
IS 'Generates a signed URL for a chat attachment after verifying the caller is a participant in the conversation.';
