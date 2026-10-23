-- Run only against the isolated, actual-schema fixture seeded by the runner.
BEGIN;
SET LOCAL statement_timeout='30s';
DO $$ BEGIN IF current_database()<>'elmam_notification_source_v2_v1' THEN RAISE EXCEPTION 'owned_notification_source_fixture_only'; END IF; END $$;
CREATE TEMP TABLE cases(name text PRIMARY KEY) ON COMMIT DROP;
CREATE FUNCTION pg_temp.require(ok boolean,name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'failed: %',name; END IF; INSERT INTO cases VALUES(name); END $$;
CREATE FUNCTION pg_temp.patient(n integer) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE result uuid:=gen_random_uuid();
BEGIN
 INSERT INTO public.patients(id,account_id,device_id,local_id,name,doctor_id,doctor_review_pending,registered_at)
 VALUES(result,'11000000-0000-4000-8000-000000009901','notification-source-fixture',n,'synthetic only',
  '51000000-0000-4000-8000-000000000003',true,'2026-10-23T00:00:00.123456Z');
 RETURN result;
END $$;
DO $$
DECLARE uid uuid:='21000000-0000-4000-8000-000000000003';
 account uuid:='11000000-0000-4000-8000-000000009901';
 owner_uid uuid:='21000000-0000-4000-8000-000000000001';
 admin_uid uuid:='21000000-0000-4000-8000-000000000007';
 install uuid:=gen_random_uuid();first_patient uuid;empty_patient uuid;rolled_patient uuid;
 original_event text;original_target uuid;original_token uuid:=gen_random_uuid();rotated_token uuid:=gen_random_uuid();
 room uuid:=gen_random_uuid();message_id uuid;request_id uuid;plan text;counted integer;before_count integer;denied boolean:=false;
 operation jsonb;receipt jsonb;sync_event jsonb;first_result jsonb;replayed_result jsonb;
BEGIN
 PERFORM pg_temp.require((SELECT NOT capture_enabled AND NOT dispatch_enabled FROM public.notification_delivery_control_v2),'rollout is disabled by default');
 INSERT INTO public.push_device_tokens(id,user_uid,account_id,platform,token,installation_id,delivery_protocol)
 VALUES(original_token,uid,account,'android','synthetic-original',install,2);
 PERFORM pg_temp.patient(1);
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM public.notification_delivery_events_v2),'disabled capture changes no source workflow and creates no queue');
 UPDATE public.notification_delivery_control_v2 SET capture_enabled=true;
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM public.notification_delivery_events_v2),'activation does not backfill historical patients');
 first_patient:=pg_temp.patient(2);
 SELECT event_id INTO STRICT original_event FROM public.notification_delivery_events_v2 WHERE source_id=first_patient;
 SELECT id INTO STRICT original_target FROM public.notification_delivery_targets_v2 WHERE event_id=original_event;
 PERFORM pg_temp.require((SELECT targets_initialized FROM public.notification_delivery_events_v2 WHERE event_id=original_event)
  AND (SELECT status='pending' AND installation_id=install AND token_id=original_token AND attempts=0 FROM public.notification_delivery_targets_v2 WHERE id=original_target),
  'source transaction durably captures the original installation before any webhook or worker');
 UPDATE public.patients SET name='synthetic edited' WHERE id=first_patient;
 UPDATE public.patients SET doctor_id=doctor_id WHERE id=first_patient;
 UPDATE public.patients SET doctor_review_pending=false WHERE id=first_patient;
 PERFORM pg_temp.require((SELECT count(*)=1 FROM public.notification_delivery_events_v2 WHERE source_id=first_patient),'name edits equal assignments and doctor review acknowledgement do not create another alert');
 UPDATE public.patients SET doctor_review_pending=true WHERE id=first_patient;
 PERFORM pg_temp.require((SELECT count(*)=2 FROM public.notification_delivery_events_v2 WHERE source_id=first_patient),'a fresh doctor review request creates its own source event');
 BEGIN
  rolled_patient:=pg_temp.patient(3);
  RAISE EXCEPTION 'simulate_source_rollback';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM<>'simulate_source_rollback' THEN RAISE; END IF;
 END;
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM public.patients WHERE id=rolled_patient)
  AND NOT EXISTS(SELECT 1 FROM public.notification_delivery_events_v2 WHERE source_id=rolled_patient),
  'source rollback removes its event and all destinations atomically');
 UPDATE public.push_device_tokens SET is_active=false WHERE id=original_token;
 INSERT INTO public.push_device_tokens(id,user_uid,account_id,platform,token,installation_id,delivery_protocol)
 VALUES(rotated_token,uid,account,'android','synthetic-rotated',install,2);
 PERFORM pg_temp.require((SELECT installation_id=install AND token_id=original_token FROM public.notification_delivery_targets_v2 WHERE id=original_target)
  AND (SELECT id=rotated_token FROM public.push_device_tokens WHERE user_uid=uid AND installation_id=install AND is_active),
  'token rotation preserves a stable destination and exposes one current registration');
 BEGIN
  INSERT INTO public.push_device_tokens(user_uid,account_id,platform,token,installation_id,delivery_protocol)
  VALUES(uid,account,'android','synthetic-duplicate-install',install,2);
 EXCEPTION WHEN unique_violation THEN denied:=true; END;
 PERFORM pg_temp.require(denied,'two active registrations cannot compete for one user installation');denied:=false;
 BEGIN
  INSERT INTO public.push_device_tokens(user_uid,account_id,platform,token,delivery_protocol)
  VALUES(uid,account,'android','synthetic-missing-install',2);
 EXCEPTION WHEN check_violation THEN denied:=true; END;
 PERFORM pg_temp.require(denied,'protocol2 requires an installation identity');
 INSERT INTO public.push_device_tokens(user_uid,account_id,platform,token) VALUES(uid,account,'android','synthetic-legacy');
 INSERT INTO public.push_device_tokens(user_uid,account_id,platform,token,installation_id,delivery_protocol)
 VALUES(uid,account,'android','synthetic-second-device',gen_random_uuid(),2);
 PERFORM pg_temp.require((SELECT count(*)=1 FROM public.notification_delivery_targets_v2 WHERE event_id=original_event),'later device registration cannot join an existing immutable snapshot');
 empty_patient:=pg_temp.patient(4);
 PERFORM pg_temp.require((SELECT count(*)=2 FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=empty_patient),
  'a new event captures both current installations and excludes legacy protocol1');
 UPDATE public.account_feature_permissions SET allowed_features=ARRAY[]::text[] WHERE user_uid=uid AND account_id=account;
 empty_patient:=pg_temp.patient(5);
 PERFORM pg_temp.require(EXISTS(SELECT 1 FROM public.notification_delivery_events_v2 WHERE source_id=empty_patient AND targets_initialized)
  AND NOT EXISTS(SELECT 1 FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=empty_patient),
  'a missing patient feature records an empty snapshot without targeting the doctor');
 UPDATE public.account_feature_permissions SET allowed_features=ARRAY['patients.list','patients.new']::text[] WHERE user_uid=uid AND account_id=account;
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=empty_patient),
  'granting a feature later does not replay a historical empty snapshot');

 operation:=jsonb_build_object('id',gen_random_uuid(),'account_id',account,'device_id','notification-source-fixture',
  'local_id',99,'name','synthetic atomic','doctor_id','51000000-0000-4000-8000-000000000003',
  'doctor_review_pending',true,'registered_at','2026-10-23T00:00:00.123456Z');
 receipt:=jsonb_build_object('id',gen_random_uuid(),'client_mutation_id','notification-source-stable-cid','payload_hash',repeat(md5(operation::text),2));
 sync_event:=jsonb_build_object('id',gen_random_uuid(),'correlation_id',gen_random_uuid());
 SELECT result_json INTO STRICT first_result FROM public.apply_clinic_sync_atomic(owner_uid,'patients','insert','0',operation,receipt,sync_event);
 SELECT result_json INTO STRICT replayed_result FROM public.apply_clinic_sync_atomic(owner_uid,'patients','insert','0',operation,receipt,sync_event);
 PERFORM pg_temp.require(first_result=replayed_result AND
  (SELECT count(*)=1 FROM public.notification_delivery_events_v2 WHERE source_id=(operation->>'id')::uuid),
  'lost sync response and exact CID replay retain one patient notification event');

 INSERT INTO public.chat_conversations(id,account_id,created_by,is_group) VALUES(room,account,owner_uid,true);
 INSERT INTO public.chat_participants(conversation_id,user_uid,account_id) VALUES(room,uid,account),(room,owner_uid,account);
 PERFORM set_config('hasura.user',json_build_object('x-hasura-user-id',owner_uid,'x-hasura-role','user')::text,true);
 INSERT INTO public.chat_messages(conversation_id,account_id,sender_uid,body) VALUES(room,account,owner_uid,'synthetic only') RETURNING id INTO message_id;
 PERFORM pg_temp.require((SELECT count(*)=2 AND bool_and(t.user_uid=uid) FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=message_id),
  'chat source captures recipient installations and never the sender');
 PERFORM set_config('hasura.user',json_build_object('x-hasura-user-id',uid,'x-hasura-role','user')::text,true);
 UPDATE public.chat_participants SET muted=true WHERE conversation_id=room AND user_uid=uid;
 PERFORM set_config('hasura.user',json_build_object('x-hasura-user-id',owner_uid,'x-hasura-role','user')::text,true);
 INSERT INTO public.chat_messages(conversation_id,account_id,sender_uid,body) VALUES(room,account,owner_uid,'synthetic muted') RETURNING id INTO message_id;
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=message_id),'muted participants are not captured');
 PERFORM set_config('hasura.user',json_build_object('x-hasura-user-id',uid,'x-hasura-role','user')::text,true);
 UPDATE public.chat_participants SET muted=false,is_deleted=true WHERE conversation_id=room AND user_uid=uid;
 PERFORM set_config('hasura.user',json_build_object('x-hasura-user-id',owner_uid,'x-hasura-role','user')::text,true);
 INSERT INTO public.chat_messages(conversation_id,account_id,sender_uid,body) VALUES(room,account,owner_uid,'synthetic removed') RETURNING id INTO message_id;
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=message_id),'removed participants cannot enter a later snapshot');

 -- The following rows are fixture/admin setup, after the signed chat writes.
 -- Application actors must use the protected installation registration RPC.
 PERFORM set_config('hasura.user','{}',true);
 INSERT INTO public.push_device_tokens(user_uid,platform,token,installation_id,delivery_protocol)
 VALUES(admin_uid,'android','synthetic-admin',gen_random_uuid(),2);
 plan:='notification_fixture';
 INSERT INTO public.subscription_plans(code,name,price_usd,duration_months,is_active) VALUES(plan,'synthetic only',0,1,true);
 INSERT INTO public.subscription_requests(account_id,user_uid,plan_code) VALUES(account,owner_uid,plan) RETURNING id INTO request_id;
 PERFORM pg_temp.require((SELECT count(*)=1 AND bool_and(t.user_uid=admin_uid) FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=request_id AND e.event_type='plan_request'),
  'pending plan request captures the active system admin without trusting token role');
 INSERT INTO public.employee_seat_requests(account_id,requested_by_uid,employee_email) VALUES(account,owner_uid,'synthetic@example.invalid') RETURNING id INTO request_id;
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM public.notification_delivery_events_v2 WHERE source_id=request_id),'unsubmitted seat request creates no admin event');
 UPDATE public.employee_seat_requests SET status='submitted' WHERE id=request_id;
 UPDATE public.employee_seat_requests SET status=status,receipt_file_id='synthetic-only' WHERE id=request_id;
 PERFORM pg_temp.require((SELECT count(*)=1 FROM public.notification_delivery_events_v2 WHERE source_id=request_id AND event_type='seat_request')
  AND (SELECT count(*)=1 FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=request_id),
  'submitted extra seat transition creates one event despite repeated status and receipt writes');

 INSERT INTO public.push_device_tokens(user_uid,account_id,platform,token,installation_id,delivery_protocol)
 SELECT uid,account,'android','synthetic-bulk-'||n,gen_random_uuid(),2 FROM generate_series(1,1001)n;
 empty_patient:=pg_temp.patient(6);
 PERFORM pg_temp.require((SELECT count(*)=1003 FROM public.notification_delivery_targets_v2 t JOIN public.notification_delivery_events_v2 e USING(event_id) WHERE e.source_id=empty_patient),
  'set based source capture does not silently truncate at 1000 destinations');
 SELECT count(*) INTO before_count FROM public.notification_delivery_events_v2;
 UPDATE public.notification_delivery_control_v2 SET capture_enabled=false;
 PERFORM pg_temp.patient(7);
 PERFORM pg_temp.require((SELECT count(*)=before_count FROM public.notification_delivery_events_v2),'disabling capture preserves existing events and stops future capture');
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('notification_capture_source_v2_internal','tg_notification_source_outbox_v2') AND a.grantee=0 AND a.privilege_type='EXECUTE'),
  'source capture helper and trigger grant no PUBLIC execute');
END $$;
SELECT json_build_object('passed',count(*),'cases',json_agg(name ORDER BY name))::text FROM cases;
ROLLBACK;
