-- Unpublished. No dispatch activation, cron change, webhook replacement or FCM.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE OR REPLACE FUNCTION public.claim_notification_targets_v2(p_worker uuid,p_limit integer DEFAULT 20)
RETURNS SETOF public.notification_delivery_targets_v2 LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE at_time timestamptz:=clock_timestamp();
BEGIN
 IF p_worker IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_worker_claim'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.notification_delivery_control_v2 WHERE singleton AND dispatch_enabled) THEN RETURN; END IF;
 WITH exhausted AS (SELECT id FROM public.notification_delivery_targets_v2 WHERE installation_id IS NOT NULL AND attempts>=8 AND (status='pending' OR status='processing' AND lease_until<=at_time) FOR UPDATE SKIP LOCKED LIMIT 100)
 UPDATE public.notification_delivery_targets_v2 AS target SET status='dead',lease_token=NULL,lease_until=NULL,updated_at=at_time,last_error_code='retry_budget_exhausted' FROM exhausted WHERE target.id=exhausted.id;
 RETURN QUERY WITH due AS (
  SELECT id FROM public.notification_delivery_targets_v2 WHERE installation_id IS NOT NULL AND attempts<8 AND next_attempt_at<=at_time
   AND (status='pending' OR status='processing' AND lease_until<=at_time)
   ORDER BY next_attempt_at,id FOR UPDATE SKIP LOCKED LIMIT p_limit
 ) UPDATE public.notification_delivery_targets_v2 AS target SET status='processing',worker_id=p_worker,
   lease_token=gen_random_uuid(),lease_until=at_time+interval '60 seconds',attempts=target.attempts+1,updated_at=at_time
   FROM due WHERE target.id=due.id RETURNING target.*;
END $$;

-- Final narrow admission uses the database clock and current authority after
-- the Hasura recipient-role read. No wall-clock estimate or active old lease
-- alone can authorize an external send. It does not assert exactly-once FCM.
CREATE FUNCTION public.admit_notification_target_v2(p_id uuid,p_lease uuid,p_registration uuid,p_token text)
RETURNS SETOF public.notification_delivery_targets_v2 LANGUAGE sql SET search_path=pg_catalog,public AS $$
 SELECT t.* FROM public.notification_delivery_targets_v2 t
 JOIN public.notification_delivery_events_v2 e ON e.event_id=t.event_id
 JOIN public.push_device_tokens r ON r.id=p_registration AND r.user_uid=t.user_uid AND r.installation_id=t.installation_id
 JOIN auth.users u ON u.id=t.user_uid
 WHERE t.id=p_id AND t.status='processing' AND t.lease_token=p_lease
  AND t.lease_until>clock_timestamp()+interval '20 seconds'
  AND u.disabled=false AND r.is_active=true AND r.delivery_protocol=2 AND r.platform='android' AND r.token=p_token
  AND EXISTS(SELECT 1 FROM public.notification_delivery_control_v2 WHERE singleton AND dispatch_enabled)
  AND (e.event_type IN ('plan_request','seat_request') OR e.account_id IS NULL OR r.account_id=e.account_id)
  AND CASE e.event_type
   WHEN 'new_patient' THEN EXISTS (
    SELECT 1 FROM public.patients p JOIN public.doctors d ON d.id=p.doctor_id AND d.account_id=p.account_id
    JOIN public.active_account_feature_access a ON a.account_id=p.account_id AND a.user_uid=d.user_uid
    WHERE p.id=e.source_id AND p.account_id=e.account_id AND p.is_deleted IS DISTINCT FROM true
     AND d.is_deleted IS DISTINCT FROM true AND d.user_uid=t.user_uid
     AND (a.allow_all OR a.allowed_features @> ARRAY['patients.list']::text[]))
   WHEN 'chat_message' THEN EXISTS (
    SELECT 1 FROM public.chat_messages m JOIN public.chat_participants cp
     ON cp.conversation_id=m.conversation_id AND cp.user_uid=t.user_uid
    WHERE m.id=e.source_id AND m.account_id IS NOT DISTINCT FROM e.account_id AND m.sender_uid<>t.user_uid
     AND m.is_deleted IS DISTINCT FROM true AND m.deleted IS DISTINCT FROM true
     AND cp.is_deleted IS DISTINCT FROM true AND NOT cp.muted AND NOT cp.archived AND NOT cp.blocked
     AND public.chat_actor_can_read(m.conversation_id,t.user_uid))
   WHEN 'plan_request' THEN EXISTS (
    SELECT 1 FROM public.subscription_requests s CROSS JOIN public.active_superadmin_identity a
    WHERE s.id=e.source_id AND s.account_id=e.account_id AND s.status='pending' AND a.user_uid=t.user_uid)
   WHEN 'seat_request' THEN EXISTS (
    SELECT 1 FROM public.employee_seat_requests s CROSS JOIN public.active_superadmin_identity a
    WHERE s.id=e.source_id AND s.account_id=e.account_id AND s.status='submitted' AND s.seat_kind='extra' AND a.user_uid=t.user_uid)
   ELSE false END;
$$;

CREATE FUNCTION public.deactivate_notification_registration_v2(p_id uuid,p_uid uuid,p_installation uuid,p_token text)
RETURNS SETOF public.push_device_tokens LANGUAGE sql SET search_path=pg_catalog,public AS $$
 UPDATE public.push_device_tokens SET is_active=false
 WHERE id=p_id AND user_uid=p_uid AND installation_id=p_installation AND token=p_token AND delivery_protocol=2 AND is_active=true
 RETURNING *;
$$;
REVOKE ALL ON FUNCTION public.claim_notification_targets_v2(uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admit_notification_target_v2(uuid,uuid,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_notification_registration_v2(uuid,uuid,uuid,text) FROM PUBLIC;
COMMIT;
