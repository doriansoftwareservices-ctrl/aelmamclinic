BEGIN;
-- A typed acknowledgement relation, private to the requesting actor and its
-- current room authority. No attachment path or other user's receipt is exposed.
CREATE OR REPLACE VIEW public.v_chat_attachment_receipt_ack WITH (security_barrier = true) AS
SELECT r.attachment_id,r.user_uid,r.device_id,r.downloaded_at,r.opened_at
FROM public.chat_attachment_receipts r
JOIN public.chat_attachments a ON a.id=r.attachment_id
JOIN public.chat_messages m ON m.id=a.message_id
JOIN public.chat_current_access access ON access.conversation_id=m.conversation_id
  AND access.user_uid=r.user_uid AND access.can_read
WHERE r.user_uid=nullif(public.request_uid_text(),'')::uuid
  AND a.is_deleted IS DISTINCT FROM true
  AND m.deleted IS DISTINCT FROM true AND m.is_deleted IS DISTINCT FROM true;

CREATE OR REPLACE FUNCTION public.chat_record_attachment_receipt(
  p_attachment_id uuid, p_device_id text, p_kind text
) RETURNS SETOF public.v_chat_attachment_receipt_ack
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $function$
DECLARE
  actor uuid := nullif(public.request_uid_text(),'')::uuid;
  room uuid;
  device text := btrim(p_device_id);
BEGIN
  IF actor IS NULL OR p_attachment_id IS NULL OR coalesce(device,'')=''
    OR p_kind IS NULL OR p_kind NOT IN ('downloaded','opened') THEN
    RAISE EXCEPTION 'attachment_receipt_invalid' USING ERRCODE='22023';
  END IF;
  SELECT m.conversation_id INTO room
  FROM public.chat_attachments a JOIN public.chat_messages m ON m.id=a.message_id
  WHERE a.id=p_attachment_id AND a.is_deleted IS DISTINCT FROM true
    AND m.deleted IS DISTINCT FROM true AND m.is_deleted IS DISTINCT FROM true;
  IF room IS NULL THEN
    RAISE EXCEPTION 'attachment_receipt_denied' USING ERRCODE='42501';
  END IF;
  PERFORM public.chat_lock_actor_scope(room,actor);
  IF NOT public.chat_actor_can_read(room,actor) THEN
    RAISE EXCEPTION 'attachment_receipt_denied' USING ERRCODE='42501';
  END IF;
  -- The message/attachment cannot be tombstoned between validation and ACK.
  PERFORM 1 FROM public.chat_attachments a JOIN public.chat_messages m ON m.id=a.message_id
  WHERE a.id=p_attachment_id AND m.conversation_id=room
    AND a.is_deleted IS DISTINCT FROM true
    AND m.deleted IS DISTINCT FROM true AND m.is_deleted IS DISTINCT FROM true
  FOR UPDATE OF a FOR SHARE OF m;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'attachment_receipt_denied' USING ERRCODE='42501';
  END IF;
  PERFORM public.chat_register_device(device,NULL,NULL);
  INSERT INTO public.chat_attachment_receipts(attachment_id,user_uid,device_id,downloaded_at,opened_at)
  VALUES(p_attachment_id,actor,device,
    CASE WHEN p_kind='downloaded' THEN clock_timestamp() END,
    CASE WHEN p_kind='opened' THEN clock_timestamp() END)
  ON CONFLICT(attachment_id,user_uid,device_id) DO UPDATE SET
    downloaded_at=coalesce(public.chat_attachment_receipts.downloaded_at,EXCLUDED.downloaded_at),
    opened_at=coalesce(public.chat_attachment_receipts.opened_at,EXCLUDED.opened_at);
  PERFORM public.chat_try_schedule_attachment_purge(p_attachment_id);
  RETURN QUERY SELECT * FROM public.v_chat_attachment_receipt_ack r
    WHERE r.attachment_id=p_attachment_id AND r.user_uid=actor AND r.device_id=device;
END;
$function$;
REVOKE ALL ON FUNCTION public.chat_record_attachment_receipt(uuid,text,text) FROM PUBLIC;
REVOKE ALL ON public.v_chat_attachment_receipt_ack FROM PUBLIC;
COMMIT;
