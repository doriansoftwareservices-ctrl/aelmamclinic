-- Hardening: secure purge + membership check for opened receipts

BEGIN;

-- Ensure opened receipts require conversation membership
CREATE OR REPLACE FUNCTION public.chat_mark_attachment_opened(
  p_attachment_id uuid,
  p_device_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_cid uuid;
BEGIN
  IF v_uid IS NULL OR p_attachment_id IS NULL OR btrim(p_device_id) = '' THEN
    RAISE EXCEPTION 'not authorized' USING errcode='42501';
  END IF;

  SELECT m.conversation_id INTO v_cid
  FROM public.chat_attachments a
  JOIN public.chat_messages m ON m.id = a.message_id
  JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
  WHERE a.id = p_attachment_id
    AND p.user_uid = v_uid
    AND COALESCE(p.is_deleted, false) = false
  LIMIT 1;

  IF v_cid IS NULL THEN
    RAISE EXCEPTION 'not allowed' USING errcode='42501';
  END IF;

  PERFORM public.chat_register_device(p_device_id, NULL, NULL);

  INSERT INTO public.chat_attachment_receipts(
    attachment_id, user_uid, device_id, opened_at
  )
  VALUES (p_attachment_id, v_uid, btrim(p_device_id), now())
  ON CONFLICT (attachment_id, user_uid, device_id)
  DO UPDATE SET
    opened_at = COALESCE(chat_attachment_receipts.opened_at, EXCLUDED.opened_at);

  PERFORM public.chat_try_schedule_attachment_purge(p_attachment_id);
END;
$$;

-- Harden purge: lock rows to avoid duplicate purge from concurrent runs
CREATE OR REPLACE FUNCTION public.chat_purge_due_attachments(
  p_limit int DEFAULT 200
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
SET row_security TO 'off'
AS $$
DECLARE
  v_count int := 0;
BEGIN
  WITH due AS (
    SELECT a.id, a.bucket, a.path
    FROM public.chat_attachments a
    JOIN public.chat_messages m ON m.id = a.message_id
    WHERE a.purge_ready = true
      AND a.purge_at IS NOT NULL
      AND a.purge_at <= now()
      AND NOT public.chat_is_support_conversation(m.conversation_id)
    ORDER BY a.purge_at
    LIMIT COALESCE(p_limit, 200)
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM storage.files f
  USING due d
  WHERE f.bucket_id = d.bucket
    AND (f.id::text = d.path OR f.name = d.path);

  WITH due AS (
    SELECT a.id
    FROM public.chat_attachments a
    JOIN public.chat_messages m ON m.id = a.message_id
    WHERE a.purge_ready = true
      AND a.purge_at IS NOT NULL
      AND a.purge_at <= now()
      AND NOT public.chat_is_support_conversation(m.conversation_id)
    ORDER BY a.purge_at
    LIMIT COALESCE(p_limit, 200)
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.chat_attachments a
  USING due d
  WHERE a.id = d.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Prevent direct calls outside Hasura permissions/cron
REVOKE ALL ON FUNCTION public.chat_purge_due_attachments(int) FROM PUBLIC;

COMMIT;
