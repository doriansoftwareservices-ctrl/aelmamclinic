BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.notification_installations_v2 (
 installation_id uuid PRIMARY KEY,
 secret_hash text NOT NULL CHECK (secret_hash ~ '^[0-9a-f]{64}$'),
 client_revision bigint NOT NULL CHECK (client_revision BETWEEN 1 AND 9007199254740991),
 bound_user_uid uuid NOT NULL,
 bound_account_id uuid,
 is_active boolean NOT NULL,
 request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
REVOKE ALL ON TABLE public.notification_installations_v2 FROM PUBLIC;

CREATE FUNCTION public.guard_notification_registration_v2()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE protected boolean;actor jsonb:=COALESCE(NULLIF(current_setting('hasura.user',true),''),'{}')::jsonb;
BEGIN
 protected:=CASE WHEN TG_OP='DELETE' THEN OLD.delivery_protocol=2
  WHEN TG_OP='UPDATE' THEN NEW.delivery_protocol=2 OR OLD.delivery_protocol=2
  ELSE NEW.delivery_protocol=2 END;
 IF protected AND NULLIF(actor->>'x-hasura-user-id','') IS NOT NULL
  AND current_setting('elmam.notification_v2_writer',true) IS DISTINCT FROM '1' THEN
  RAISE EXCEPTION 'notification_registration_endpoint_required' USING ERRCODE='42501';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER notification_registration_v2_guard BEFORE INSERT OR UPDATE OR DELETE
 ON public.push_device_tokens FOR EACH ROW EXECUTE FUNCTION public.guard_notification_registration_v2();
REVOKE ALL ON FUNCTION public.guard_notification_registration_v2() FROM PUBLIC;

CREATE FUNCTION public.register_notification_installation_v2(
 p_actor uuid,p_installation uuid,p_secret_hash text,p_revision bigint,p_account uuid,
 p_token text,p_locale text,p_request_hash text,p_deactivate boolean DEFAULT false)
RETURNS SETOF public.notification_installations_v2 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE saved public.notification_installations_v2;previous text:=current_setting('elmam.notification_v2_writer',true);
BEGIN
 IF p_actor IS NULL OR p_installation IS NULL OR p_revision IS NULL OR p_revision NOT BETWEEN 1 AND 9007199254740991
  OR p_secret_hash IS NULL OR p_secret_hash !~ '^[0-9a-f]{64}$' OR p_request_hash IS NULL OR p_request_hash !~ '^[0-9a-f]{64}$'
  OR p_deactivate IS NULL OR p_locale IS NULL OR p_locale NOT IN ('ar','en')
  OR NOT p_deactivate AND (p_token IS NULL OR length(btrim(p_token))=0 OR octet_length(p_token)>4096) THEN
  RAISE EXCEPTION 'notification_registration_invalid' USING ERRCODE='22023';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users WHERE id=p_actor AND disabled=false) THEN
  RAISE EXCEPTION 'notification_registration_denied' USING ERRCODE='42501';
 END IF;
 IF NOT p_deactivate AND p_account IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.accounts WHERE id=p_account AND frozen IS DISTINCT FROM true) THEN
  RAISE EXCEPTION 'notification_registration_denied' USING ERRCODE='42501';
 END IF;
 IF NOT p_deactivate AND p_account IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM public.account_users au JOIN public.accounts a ON a.id=au.account_id
  WHERE au.user_uid=p_actor AND au.account_id=p_account AND au.disabled IS DISTINCT FROM true AND a.frozen IS DISTINCT FROM true)
  AND NOT EXISTS(SELECT 1 FROM public.active_superadmin_identity WHERE user_uid=p_actor) THEN
  RAISE EXCEPTION 'notification_registration_denied' USING ERRCODE='42501';
 END IF;
 -- Registration is short and infrequent. One lock avoids token/install lock
 -- inversions when two installations rotate/rebind their globally unique token.
 PERFORM pg_advisory_xact_lock(hashtextextended('notification-registration-v2',0));
 SELECT * INTO saved FROM public.notification_installations_v2 WHERE installation_id=p_installation FOR UPDATE;
 IF FOUND THEN
  IF saved.secret_hash<>p_secret_hash THEN RAISE EXCEPTION 'notification_installation_secret_mismatch' USING ERRCODE='42501'; END IF;
  IF p_revision<saved.client_revision THEN RAISE EXCEPTION 'notification_registration_stale' USING ERRCODE='23514'; END IF;
  IF p_revision=saved.client_revision THEN
   IF saved.request_hash<>p_request_hash OR saved.bound_user_uid<>p_actor THEN
    RAISE EXCEPTION 'notification_registration_identity_mismatch' USING ERRCODE='23514';
   END IF;
   RETURN NEXT saved;RETURN;
  END IF;
  IF p_deactivate AND saved.bound_user_uid<>p_actor THEN
   RAISE EXCEPTION 'notification_registration_stale' USING ERRCODE='23514';
  END IF;
 END IF;
 IF NOT p_deactivate AND p_account IS NULL AND NOT (
  EXISTS(SELECT 1 FROM public.active_superadmin_identity WHERE user_uid=p_actor) OR
  EXISTS(SELECT 1 FROM public.chat_support_agents WHERE user_uid=p_actor AND is_active=true) OR
  EXISTS(SELECT 1 FROM public.account_users au JOIN public.accounts a ON a.id=au.account_id
   WHERE au.user_uid=p_actor AND au.disabled IS DISTINCT FROM true AND a.frozen IS DISTINCT FROM true)) THEN
  RAISE EXCEPTION 'notification_registration_denied' USING ERRCODE='42501';
 END IF;
 PERFORM set_config('elmam.notification_v2_writer','1',true);
 UPDATE public.push_device_tokens SET is_active=false
  WHERE installation_id=p_installation AND delivery_protocol=2 AND is_active;
 IF NOT p_deactivate THEN
  INSERT INTO public.push_device_tokens(user_uid,account_id,role,platform,token,is_active,locale_code,installation_id,delivery_protocol)
  VALUES(p_actor,p_account,NULL,'android',p_token,true,p_locale,p_installation,2)
  ON CONFLICT(token) DO UPDATE SET user_uid=p_actor,account_id=p_account,role=NULL,
   platform='android',is_active=true,locale_code=p_locale,installation_id=p_installation,delivery_protocol=2;
 END IF;
 INSERT INTO public.notification_installations_v2(installation_id,secret_hash,client_revision,bound_user_uid,bound_account_id,is_active,request_hash)
 VALUES(p_installation,p_secret_hash,p_revision,p_actor,p_account,NOT p_deactivate,p_request_hash)
 ON CONFLICT(installation_id) DO UPDATE SET client_revision=p_revision,bound_user_uid=p_actor,
  bound_account_id=p_account,is_active=NOT p_deactivate,request_hash=p_request_hash,updated_at=clock_timestamp()
 RETURNING * INTO saved;
 PERFORM set_config('elmam.notification_v2_writer',COALESCE(previous,''),true);
 RETURN NEXT saved;
END $$;
REVOKE ALL ON FUNCTION public.register_notification_installation_v2(uuid,uuid,text,bigint,uuid,text,text,text,boolean) FROM PUBLIC;

-- Known provider acceptance is not a device receipt. Retry unacknowledged
-- destinations after3 minutes, retaining event/target/nonce and the bounded
-- eight-attempt budget. Immediate partial retries never resend accepted targets.
CREATE OR REPLACE FUNCTION public.claim_notification_targets_v2(p_worker uuid,p_limit integer DEFAULT 20)
RETURNS SETOF public.notification_delivery_targets_v2 LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE at_time timestamptz:=clock_timestamp();
BEGIN
 IF p_worker IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_worker_claim'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.notification_delivery_control_v2 WHERE singleton AND dispatch_enabled) THEN RETURN; END IF;
 WITH exhausted AS (SELECT id FROM public.notification_delivery_targets_v2 WHERE installation_id IS NOT NULL AND attempts>=8
  AND (status='pending' OR status='processing' AND lease_until<=at_time OR status='accepted' AND next_attempt_at<=at_time)
  FOR UPDATE SKIP LOCKED LIMIT 100)
 UPDATE public.notification_delivery_targets_v2 t SET status='dead',lease_token=NULL,lease_until=NULL,
  updated_at=at_time,last_error_code='retry_budget_exhausted' FROM exhausted x WHERE t.id=x.id;
 RETURN QUERY WITH due AS (SELECT id FROM public.notification_delivery_targets_v2
  WHERE installation_id IS NOT NULL AND attempts<8 AND next_attempt_at<=at_time
   AND (status IN ('pending','accepted') OR status='processing' AND lease_until<=at_time)
  ORDER BY next_attempt_at,id FOR UPDATE SKIP LOCKED LIMIT p_limit)
 UPDATE public.notification_delivery_targets_v2 t SET status='processing',worker_id=p_worker,lease_token=gen_random_uuid(),
  lease_until=at_time+interval '60 seconds',attempts=t.attempts+1,updated_at=at_time FROM due WHERE t.id=due.id RETURNING t.*;
END $$;

CREATE OR REPLACE FUNCTION public.notification_finish_target_v2_internal(p_id uuid,p_lease uuid,p_outcome text,p_error text DEFAULT NULL,p_provider_message_id text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE saved public.notification_delivery_targets_v2;at_time timestamptz:=clock_timestamp();
BEGIN
 IF p_outcome IS NULL OR p_outcome NOT IN ('accepted','retryable','cancelled') OR p_error IS NOT NULL AND p_error !~ '^[a-z_0-9]{1,80}$'
  OR p_outcome='accepted' AND (p_provider_message_id IS NULL OR length(btrim(p_provider_message_id)) NOT BETWEEN 1 AND 512) THEN
  RAISE EXCEPTION 'invalid_delivery_outcome';END IF;
 SELECT * INTO saved FROM public.notification_delivery_targets_v2
  WHERE id=p_id AND status='processing' AND lease_token=p_lease AND lease_until>at_time FOR UPDATE;
 IF NOT FOUND THEN RETURN false;END IF;
 at_time:=clock_timestamp();IF saved.lease_until<=at_time THEN RETURN false;END IF;
 UPDATE public.notification_delivery_targets_v2 SET
  status=CASE WHEN p_outcome='accepted' THEN 'accepted' WHEN p_outcome='cancelled' THEN 'cancelled' WHEN saved.attempts>=8 THEN 'dead' ELSE 'pending' END,
  provider_accepted_at=CASE WHEN p_outcome='accepted' THEN at_time ELSE provider_accepted_at END,
  provider_message_id=CASE WHEN p_outcome='accepted' THEN p_provider_message_id ELSE provider_message_id END,
  next_attempt_at=CASE WHEN p_outcome='accepted' THEN at_time+interval '3 minutes'
   WHEN p_outcome='retryable' THEN at_time+make_interval(secs=>LEAST(300,5*(2^LEAST(saved.attempts,6))::integer)) ELSE next_attempt_at END,
  lease_token=NULL,lease_until=NULL,updated_at=at_time,last_error_code=CASE WHEN p_outcome='accepted' THEN NULL ELSE p_error END WHERE id=p_id;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.claim_notification_targets_v2(uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.notification_finish_target_v2_internal(uuid,uuid,text,text,text) FROM PUBLIC;
COMMIT;
