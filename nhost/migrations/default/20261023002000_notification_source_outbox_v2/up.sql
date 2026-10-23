-- Unpublished candidate. Capture and dispatch are OFF until the v2 client,
-- registration, dispatcher, scheduler and native acceptance gates all pass.
-- Only future source transactions are captured; no historical replay/backfill.
BEGIN;
SET LOCAL lock_timeout='5s';

ALTER TABLE public.push_device_tokens
 ADD COLUMN installation_id uuid,
 ADD COLUMN delivery_protocol smallint NOT NULL DEFAULT 1,
 ADD CONSTRAINT push_delivery_protocol_v2_check CHECK
  (delivery_protocol=1 OR delivery_protocol=2 AND installation_id IS NOT NULL AND platform='android');
CREATE UNIQUE INDEX push_active_installation_v2
 ON public.push_device_tokens(user_uid,installation_id)
 WHERE delivery_protocol=2 AND is_active=true;

ALTER TABLE public.notification_delivery_events_v2
 DROP CONSTRAINT notification_delivery_events_v2_event_type_check,
 ADD CONSTRAINT notification_delivery_events_v2_event_type_check CHECK
  (event_type IN ('chat_message','new_patient','plan_request','seat_request'));
ALTER TABLE public.notification_delivery_targets_v2 ADD COLUMN installation_id uuid;
CREATE UNIQUE INDEX notification_event_installation_v2
 ON public.notification_delivery_targets_v2(event_id,user_uid,installation_id)
 WHERE installation_id IS NOT NULL;

CREATE TABLE public.notification_delivery_control_v2 (
 singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
 capture_enabled boolean NOT NULL DEFAULT false,
 dispatch_enabled boolean NOT NULL DEFAULT false,
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK (NOT dispatch_enabled OR capture_enabled)
);
INSERT INTO public.notification_delivery_control_v2(singleton) VALUES(true);
REVOKE ALL ON TABLE public.notification_delivery_control_v2 FROM PUBLIC;

-- Called only by the source trigger. The set-based snapshot has no webhook
-- dependency or artificial 1000-target truncation. One installation is one
-- destination; token rotation does not create another destination for an event.
CREATE FUNCTION public.notification_capture_source_v2_internal(
 p_kind text,p_source uuid,p_account uuid,p_recipients uuid[])
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE event_key text;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM public.notification_delivery_control_v2
  WHERE singleton AND capture_enabled) THEN RETURN NULL; END IF;
 event_key:='nev2_'||replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 INSERT INTO public.notification_delivery_events_v2(event_id,event_type,source_id,account_id,targets_initialized)
 VALUES(event_key,p_kind,p_source,p_account,true);
 INSERT INTO public.notification_delivery_targets_v2(event_id,user_uid,token_id,installation_id)
 SELECT event_key,t.user_uid,t.id,t.installation_id
 FROM public.push_device_tokens t JOIN auth.users u ON u.id=t.user_uid
 WHERE t.user_uid=ANY(p_recipients) AND t.is_active=true AND u.disabled=false
  AND t.delivery_protocol=2 AND t.installation_id IS NOT NULL AND t.platform='android' AND length(btrim(t.token))>0
  AND (p_kind IN ('plan_request','seat_request') OR p_account IS NULL OR t.account_id=p_account);
 RETURN event_key;
END $$;

CREATE FUNCTION public.tg_notification_source_outbox_v2()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE kind text;recipients uuid[];
BEGIN
 IF NOT EXISTS (SELECT 1 FROM public.notification_delivery_control_v2
  WHERE singleton AND capture_enabled) THEN RETURN NEW; END IF;
 CASE TG_TABLE_NAME
 WHEN 'chat_messages' THEN
  IF NEW.is_deleted IS TRUE OR NEW.deleted IS TRUE THEN RETURN NEW; END IF;
  kind:='chat_message';
  SELECT array_agg(DISTINCT cp.user_uid) INTO recipients
   FROM public.chat_participants cp
   WHERE cp.conversation_id=NEW.conversation_id AND cp.is_deleted IS DISTINCT FROM true
    AND cp.user_uid<>NEW.sender_uid AND cp.muted IS DISTINCT FROM true AND cp.archived IS DISTINCT FROM true
    AND cp.blocked IS DISTINCT FROM true;
 WHEN 'patients' THEN
  IF NEW.is_deleted IS TRUE OR NEW.doctor_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' THEN
   -- Assignment or a new request for doctor review, never a name-only edit or
   -- the doctor's acknowledgement of that request.
   IF NEW.doctor_id IS NOT DISTINCT FROM OLD.doctor_id AND
    NOT (NEW.doctor_review_pending IS TRUE AND OLD.doctor_review_pending IS DISTINCT FROM true)
    THEN RETURN NEW; END IF;
  END IF;
  kind:='new_patient';
  SELECT array_agg(DISTINCT d.user_uid) INTO recipients
   FROM public.doctors d JOIN public.active_account_feature_access a
    ON a.account_id=d.account_id AND a.user_uid=d.user_uid
   WHERE d.id=NEW.doctor_id AND d.account_id=NEW.account_id AND d.is_deleted IS DISTINCT FROM true
    AND (a.allow_all OR a.allowed_features @> ARRAY['patients.list']::text[]);
 WHEN 'subscription_requests' THEN
  IF NEW.status<>'pending' THEN RETURN NEW; END IF;
  kind:='plan_request';
  SELECT array_agg(s.user_uid) INTO recipients FROM public.active_superadmin_identity s;
 WHEN 'employee_seat_requests' THEN
  IF NEW.status<>'submitted' OR NEW.seat_kind<>'extra' THEN RETURN NEW; END IF;
  -- A receipt/payment-method edit while already submitted is not a new request.
  IF TG_OP='UPDATE' THEN
   IF OLD.status='submitted' THEN RETURN NEW; END IF;
  END IF;
  kind:='seat_request';
  SELECT array_agg(s.user_uid) INTO recipients FROM public.active_superadmin_identity s;
 ELSE RAISE EXCEPTION 'unsupported_notification_source';
 END CASE;
 PERFORM public.notification_capture_source_v2_internal(kind,NEW.id,NEW.account_id,recipients);
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.notification_capture_source_v2_internal(text,uuid,uuid,uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.tg_notification_source_outbox_v2() FROM PUBLIC;

CREATE TRIGGER notification_source_outbox_v2 AFTER INSERT ON public.chat_messages
 FOR EACH ROW EXECUTE FUNCTION public.tg_notification_source_outbox_v2();
CREATE TRIGGER notification_source_outbox_v2 AFTER INSERT OR UPDATE OF doctor_id,doctor_review_pending ON public.patients
 FOR EACH ROW EXECUTE FUNCTION public.tg_notification_source_outbox_v2();
CREATE TRIGGER notification_source_outbox_v2 AFTER INSERT ON public.subscription_requests
 FOR EACH ROW EXECUTE FUNCTION public.tg_notification_source_outbox_v2();
CREATE TRIGGER notification_source_outbox_v2 AFTER INSERT OR UPDATE OF status ON public.employee_seat_requests
 FOR EACH ROW EXECUTE FUNCTION public.tg_notification_source_outbox_v2();
COMMIT;
