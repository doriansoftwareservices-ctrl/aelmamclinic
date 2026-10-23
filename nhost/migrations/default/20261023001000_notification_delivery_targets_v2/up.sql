-- Candidate only: not deployed. Queue storage is independent of the legacy
-- notification_event_deliveries protocol; no old uncertain event is replayed.
-- Server Functions alone will expose typed enqueue/claim/outcome/ACK operations.
-- This migration by itself does not implement authority resolution, dispatch,
-- a retry scheduler, device registration, or persistent native display dedup.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.notification_delivery_events_v2 (
 event_id text PRIMARY KEY CHECK (event_id ~ '^nev2_[0-9a-f]{64}$'),
 event_type text NOT NULL CHECK (event_type IN ('chat_message','new_patient','plan_request')),
 source_id uuid NOT NULL,
 account_id uuid,
 targets_initialized boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.notification_delivery_targets_v2 (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 event_id text NOT NULL REFERENCES public.notification_delivery_events_v2(event_id),
 user_uid uuid NOT NULL,
 token_id uuid NOT NULL,
 ack_nonce uuid NOT NULL DEFAULT gen_random_uuid(),
 status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','accepted','acknowledged','cancelled','dead')),
 attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 8),
 worker_id uuid,
 lease_token uuid,
 lease_until timestamptz,
 next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 provider_accepted_at timestamptz,
 provider_message_id text,
 acknowledged_at timestamptz,
 last_error_code text,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(event_id,user_uid,token_id),
 CHECK ((status='processing' AND lease_token IS NOT NULL AND lease_until IS NOT NULL) OR (status<>'processing' AND lease_token IS NULL AND lease_until IS NULL)),
 CHECK (status<>'accepted' OR provider_accepted_at IS NOT NULL AND provider_message_id IS NOT NULL AND length(btrim(provider_message_id))>0),
 CHECK (status<>'acknowledged' OR acknowledged_at IS NOT NULL)
);
CREATE INDEX notification_target_due_v2 ON public.notification_delivery_targets_v2(next_attempt_at,id) WHERE status IN ('pending','processing');
CREATE OR REPLACE FUNCTION public.enqueue_notification_delivery_v2(p_event text,p_kind text,p_source uuid,p_account uuid,p_targets jsonb)
RETURNS SETOF public.notification_delivery_targets_v2 LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE saved public.notification_delivery_events_v2;
BEGIN
 IF jsonb_typeof(p_targets) IS DISTINCT FROM 'array' OR jsonb_array_length(p_targets)>1000 THEN RAISE EXCEPTION 'invalid_target_snapshot'; END IF;
 INSERT INTO public.notification_delivery_events_v2(event_id,event_type,source_id,account_id) VALUES(p_event,p_kind,p_source,p_account) ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT saved FROM public.notification_delivery_events_v2 WHERE event_id=p_event FOR UPDATE;
 IF saved.event_type<>p_kind OR saved.source_id<>p_source OR saved.account_id IS DISTINCT FROM p_account THEN RAISE EXCEPTION 'event_identity_mismatch'; END IF;
 IF NOT saved.targets_initialized THEN
  INSERT INTO public.notification_delivery_targets_v2(event_id,user_uid,token_id)
   SELECT p_event,(value->>'user_uid')::uuid,(value->>'token_id')::uuid FROM jsonb_array_elements(p_targets);
  UPDATE public.notification_delivery_events_v2 SET targets_initialized=true WHERE event_id=p_event;
 END IF;
 RETURN QUERY SELECT * FROM public.notification_delivery_targets_v2 WHERE event_id=p_event ORDER BY id;
END $$;
CREATE OR REPLACE FUNCTION public.claim_notification_targets_v2(p_worker uuid,p_limit integer DEFAULT 20)
RETURNS SETOF public.notification_delivery_targets_v2 LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE at_time timestamptz:=clock_timestamp();
BEGIN
 IF p_worker IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_worker_claim'; END IF;
 WITH exhausted AS (SELECT id FROM public.notification_delivery_targets_v2 WHERE attempts>=8 AND (status='pending' OR status='processing' AND lease_until<=at_time) FOR UPDATE SKIP LOCKED LIMIT 100)
 UPDATE public.notification_delivery_targets_v2 AS target SET status='dead',lease_token=NULL,lease_until=NULL,updated_at=at_time,last_error_code='retry_budget_exhausted' FROM exhausted WHERE target.id=exhausted.id;
 RETURN QUERY WITH due AS (
  SELECT id FROM public.notification_delivery_targets_v2 WHERE attempts<8 AND next_attempt_at<=at_time
   AND (status='pending' OR status='processing' AND lease_until<=at_time)
   ORDER BY next_attempt_at,id FOR UPDATE SKIP LOCKED LIMIT p_limit
 ) UPDATE public.notification_delivery_targets_v2 AS target SET status='processing',worker_id=p_worker,
   lease_token=gen_random_uuid(),lease_until=at_time+interval '60 seconds',attempts=target.attempts+1,updated_at=at_time
   FROM due WHERE target.id=due.id RETURNING target.*;
END $$;
CREATE OR REPLACE FUNCTION public.notification_finish_target_v2_internal(p_id uuid,p_lease uuid,p_outcome text,p_error text DEFAULT NULL,p_provider_message_id text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE saved public.notification_delivery_targets_v2;at_time timestamptz:=clock_timestamp();
BEGIN
 IF p_outcome IS NULL OR p_outcome NOT IN ('accepted','retryable','cancelled') OR p_error IS NOT NULL AND p_error !~ '^[a-z_0-9]{1,80}$' OR p_outcome='accepted' AND (p_provider_message_id IS NULL OR length(btrim(p_provider_message_id)) NOT BETWEEN 1 AND 512) THEN RAISE EXCEPTION 'invalid_delivery_outcome'; END IF;
 SELECT * INTO saved FROM public.notification_delivery_targets_v2 WHERE id=p_id AND status='processing' AND lease_token=p_lease AND lease_until>at_time FOR UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 at_time:=clock_timestamp();
 IF saved.lease_until<=at_time THEN RETURN false; END IF;
 UPDATE public.notification_delivery_targets_v2 SET
  status=CASE WHEN p_outcome='accepted' THEN 'accepted' WHEN p_outcome='cancelled' THEN 'cancelled' WHEN saved.attempts>=8 THEN 'dead' ELSE 'pending' END,
  provider_accepted_at=CASE WHEN p_outcome='accepted' THEN at_time ELSE provider_accepted_at END,
  provider_message_id=CASE WHEN p_outcome='accepted' THEN p_provider_message_id ELSE provider_message_id END,
  next_attempt_at=CASE WHEN p_outcome='retryable' THEN at_time+make_interval(secs=>LEAST(300,5*(2^LEAST(saved.attempts,6))::integer)) ELSE next_attempt_at END,
  lease_token=NULL,lease_until=NULL,updated_at=at_time,last_error_code=CASE WHEN p_outcome='accepted' THEN NULL ELSE p_error END
 WHERE id=p_id;
 RETURN true;
END $$;
CREATE OR REPLACE FUNCTION public.notification_ack_target_v2_internal(p_id uuid,p_actor uuid,p_nonce uuid)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE saved public.notification_delivery_targets_v2;at_time timestamptz:=clock_timestamp();
BEGIN
 SELECT * INTO saved FROM public.notification_delivery_targets_v2 WHERE id=p_id AND user_uid=p_actor AND ack_nonce=p_nonce FOR UPDATE;
 IF NOT FOUND OR saved.status='cancelled' THEN RETURN false; END IF;
 IF saved.status='acknowledged' THEN RETURN true; END IF;
 UPDATE public.notification_delivery_targets_v2 SET status='acknowledged',acknowledged_at=at_time,
  lease_token=NULL,lease_until=NULL,updated_at=at_time WHERE id=p_id;
 RETURN true;
END $$;

CREATE FUNCTION public.finish_notification_target_v2(p_id uuid,p_lease uuid,p_outcome text,p_error text DEFAULT NULL,p_provider_message_id text DEFAULT NULL)
RETURNS SETOF public.notification_delivery_targets_v2 LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF public.notification_finish_target_v2_internal(p_id,p_lease,p_outcome,p_error,p_provider_message_id) THEN
  RETURN QUERY SELECT * FROM public.notification_delivery_targets_v2 WHERE id=p_id;
 END IF;
END $$;
CREATE FUNCTION public.acknowledge_notification_target_v2(p_id uuid,p_actor uuid,p_nonce uuid)
RETURNS SETOF public.notification_delivery_targets_v2 LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
BEGIN
 IF public.notification_ack_target_v2_internal(p_id,p_actor,p_nonce) THEN
  RETURN QUERY SELECT * FROM public.notification_delivery_targets_v2 WHERE id=p_id;
 END IF;
END $$;
REVOKE ALL ON TABLE public.notification_delivery_events_v2,public.notification_delivery_targets_v2 FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enqueue_notification_delivery_v2(text,text,uuid,uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_notification_targets_v2(uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.notification_finish_target_v2_internal(uuid,uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.notification_ack_target_v2_internal(uuid,uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finish_notification_target_v2(uuid,uuid,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.acknowledge_notification_target_v2(uuid,uuid,uuid) FROM PUBLIC;
COMMIT;
