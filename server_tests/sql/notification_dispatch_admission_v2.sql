BEGIN;
SET LOCAL statement_timeout='30s';
DO $$ BEGIN IF current_database()<>'elmam_notification_source_v2_v1' THEN RAISE EXCEPTION 'owned_notification_source_fixture_only'; END IF; END $$;
CREATE TEMP TABLE cases(name text PRIMARY KEY) ON COMMIT DROP;
CREATE FUNCTION pg_temp.require(ok boolean,name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'failed: %',name; END IF; INSERT INTO cases VALUES(name); END $$;
DO $$
DECLARE uid uuid:='21000000-0000-4000-8000-000000000003';
 account uuid:='11000000-0000-4000-8000-000000009901';
 registration uuid:=gen_random_uuid();installation uuid:=gen_random_uuid();patient uuid:=gen_random_uuid();
 target public.notification_delivery_targets_v2;replacement public.notification_delivery_targets_v2;n integer;
BEGIN
 INSERT INTO public.push_device_tokens(id,user_uid,account_id,platform,token,installation_id,delivery_protocol)
 VALUES(registration,uid,account,'android','synthetic-before-rotation',installation,2);
 UPDATE public.notification_delivery_control_v2 SET capture_enabled=true;
 INSERT INTO public.patients(id,account_id,device_id,local_id,name,doctor_id,registered_at)
 VALUES(patient,account,'notification-admission-fixture',1,'synthetic only',
  '51000000-0000-4000-8000-000000000003','2026-10-23T00:00:00.123456Z');
 SELECT count(*) INTO n FROM public.claim_notification_targets_v2(gen_random_uuid(),8);
 PERFORM pg_temp.require(n=0 AND (SELECT attempts=0 FROM public.notification_delivery_targets_v2),
  'disabled dispatch cannot claim or consume retry budget');
 UPDATE public.notification_delivery_control_v2 SET dispatch_enabled=true;
 SELECT * INTO STRICT target FROM public.claim_notification_targets_v2(gen_random_uuid(),1);
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=1,'current source authority registration and live server lease admit one destination');
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,gen_random_uuid(),registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'wrong lease cannot authorize provider send');
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,gen_random_uuid(),'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'another registration cannot substitute the captured installation');
 UPDATE public.notification_delivery_targets_v2 SET lease_until=clock_timestamp()+interval '19 seconds' WHERE id=target.id;
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'insufficient server lease time cannot start provider transport');
 UPDATE public.notification_delivery_targets_v2 SET lease_until=clock_timestamp()+interval '60 seconds' WHERE id=target.id;
 UPDATE public.accounts SET frozen=true WHERE id=account;
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'clinic freeze between source read and send denies admission');
 UPDATE public.accounts SET frozen=false WHERE id=account;
 UPDATE public.account_users SET disabled=true WHERE user_uid=uid AND account_id=account;
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'membership revocation between source read and send denies admission');
 UPDATE public.account_users SET disabled=false WHERE user_uid=uid AND account_id=account;
 UPDATE public.account_feature_permissions SET allowed_features=ARRAY[]::text[] WHERE user_uid=uid AND account_id=account;
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'feature revocation between source read and send denies admission');
 UPDATE public.account_feature_permissions SET allowed_features=ARRAY['patients.list','patients.new']::text[] WHERE user_uid=uid AND account_id=account;
 UPDATE auth.users SET disabled=true WHERE id=uid;
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'disabled Auth cannot pass final admission');
 UPDATE auth.users SET disabled=false WHERE id=uid;
 UPDATE public.patients SET is_deleted=true WHERE id=patient;
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'deleted source cannot pass final admission');
 UPDATE public.patients SET is_deleted=false WHERE id=patient;
 UPDATE public.push_device_tokens SET token='synthetic-after-rotation' WHERE id=registration;
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0,'a token rotated after authority read requires a fresh read before send');
 SELECT count(*) INTO n FROM public.deactivate_notification_registration_v2(registration,uid,installation,'synthetic-before-rotation');
 PERFORM pg_temp.require(n=0 AND (SELECT is_active FROM public.push_device_tokens WHERE id=registration),
  'late invalid token result cannot deactivate its concurrently rotated replacement');
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-after-rotation');
 PERFORM pg_temp.require(n=1,'freshly resolved rotated token retains the original target');
 SELECT count(*) INTO n FROM public.deactivate_notification_registration_v2(registration,uid,installation,'synthetic-after-rotation');
 PERFORM pg_temp.require(n=1 AND (SELECT NOT is_active FROM public.push_device_tokens WHERE id=registration),
  'confirmed invalid exact registration is deactivated with compare and set');
 UPDATE public.push_device_tokens SET is_active=true WHERE id=registration;
 UPDATE public.notification_delivery_control_v2 SET dispatch_enabled=false;
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-after-rotation');
 PERFORM pg_temp.require(n=0,'dispatch cutover barrier is checked again immediately before send');
 UPDATE public.notification_delivery_control_v2 SET dispatch_enabled=true;
 UPDATE public.notification_delivery_targets_v2 SET lease_until=clock_timestamp()-interval '1 second' WHERE id=target.id;
 SELECT * INTO STRICT replacement FROM public.claim_notification_targets_v2(gen_random_uuid(),1);
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(target.id,target.lease_token,registration,'synthetic-after-rotation');
 PERFORM pg_temp.require(n=0 AND replacement.id=target.id AND replacement.lease_token<>target.lease_token AND replacement.ack_nonce=target.ack_nonce,
  'expired worker cannot send after recovery changes its lease but preserves destination identity');
 SELECT count(*) INTO n FROM public.finish_notification_target_v2(replacement.id,replacement.lease_token,'accepted',NULL,'projects/fixture/messages/known-acceptance');
 PERFORM pg_temp.require(n=1,'post send provider result remains a typed known acceptance');
 SELECT count(*) INTO n FROM public.admit_notification_target_v2(replacement.id,replacement.lease_token,registration,'synthetic-after-rotation');
 PERFORM pg_temp.require(n=0,'known accepted target cannot pass admission a second time');
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('admit_notification_target_v2','deactivate_notification_registration_v2') AND a.grantee=0 AND a.privilege_type='EXECUTE'),
  'admission and registration cleanup grant no PUBLIC execute');
END $$;
SELECT json_build_object('passed',count(*),'cases',json_agg(name ORDER BY name))::text FROM cases;
ROLLBACK;
