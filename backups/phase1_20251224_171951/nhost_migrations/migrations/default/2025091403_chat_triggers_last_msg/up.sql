-- 20250914_chat_triggers_last_msg.sql
-- تحديث last_msg_at / last_msg_snippet تلقائياً بناءً على chat_messages.

SET search_path TO public;
-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ 1) Helper: بناء مقتطف الرسالة داخل SQL                                      │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
-- لا حاجة لدالة منفصلة للمقتطف؛ سنحسبه داخل دالة التحديث الرئيسية.

-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ 2) Function: تحديث ملخص محادثة واحدة                                        │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
CREATE OR REPLACE FUNCTION public.fn_chat_refresh_last_msg(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_last_at    timestamptz;
  v_last_kind  text;
  v_last_body  text;
  v_snippet    text;
BEGIN
  -- اجلب أحدث رسالة غير محذوفة
  SELECT m.created_at, m.kind::text, m.body
    INTO v_last_at, v_last_kind, v_last_body
  FROM public.chat_messages m
  WHERE m.conversation_id = p_conversation_id
    AND COALESCE(m.deleted, false) = false
  ORDER BY m.created_at DESC
  LIMIT 1;

  IF v_last_at IS NULL THEN
    -- لا رسائل (أو كلها محذوفة)
    UPDATE public.chat_conversations
       SET last_msg_at = NULL,
           last_msg_snippet = NULL
     WHERE id = p_conversation_id;
    RETURN;
  END IF;

  -- ابنِ الـ snippet
  IF lower(coalesce(v_last_kind,'')) LIKE '%image%' OR lower(coalesce(v_last_kind,'')) = 'image' THEN
    v_snippet := '📷 صورة';
  ELSE
    -- نص: تقليم للمسافات والأسطر ثم قص إلى 64 وإضافة "…"
    v_last_body := btrim(coalesce(v_last_body, ''));
    IF v_last_body = '' THEN
      v_snippet := 'رسالة';
    ELSE
      IF length(v_last_body) > 64 THEN
        v_snippet := substring(v_last_body from 1 for 64) || '…';
      ELSE
        v_snippet := v_last_body;
      END IF;
    END IF;
  END IF;

  -- حدّث المحادثة
  UPDATE public.chat_conversations
     SET last_msg_at      = v_last_at,
         last_msg_snippet = v_snippet
   WHERE id = p_conversation_id;
END;
$$;
-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ 3) Trigger Function: استدعاء التحديث عند INSERT/UPDATE/DELETE               │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
CREATE OR REPLACE FUNCTION public.fn_chat_messages_touch_last_msg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_cid uuid;
BEGIN
  v_cid := COALESCE(NEW.conversation_id, OLD.conversation_id);
  PERFORM public.fn_chat_refresh_last_msg(v_cid);
  RETURN COALESCE(NEW, OLD);
END;
$$;
-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ 4) Triggers على chat_messages                                               │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
-- بعد الإدراج أو التعديل على الحقول المؤثرة (body/kind/deleted/created_at) نحدّث الملخّص.
DROP TRIGGER IF EXISTS trg_chat_messages_last_msg_upd ON public.chat_messages;
CREATE TRIGGER trg_chat_messages_last_msg_upd
AFTER INSERT OR UPDATE OF body, kind, deleted, created_at ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.fn_chat_messages_touch_last_msg();
-- في حال وُجد حذف فعلي (hard delete) لأي سبب، نحدّث الملخص أيضًا.
DROP TRIGGER IF EXISTS trg_chat_messages_last_msg_del ON public.chat_messages;
CREATE TRIGGER trg_chat_messages_last_msg_del
AFTER DELETE ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.fn_chat_messages_touch_last_msg();
-- انتهى;
