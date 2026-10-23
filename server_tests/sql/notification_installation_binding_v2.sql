BEGIN;
SET LOCAL statement_timeout='30s';
DO $$ BEGIN IF current_database()<>'elmam_notification_source_v2_v1' THEN RAISE EXCEPTION 'owned_fixture_only';END IF;END $$;
CREATE TEMP TABLE cases(name text PRIMARY KEY) ON COMMIT DROP;
CREATE FUNCTION pg_temp.require(ok boolean,name text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'failed: %',name;END IF;INSERT INTO cases VALUES(name);END $$;
DO $$
DECLARE uid uuid:='21000000-0000-4000-8000-000000000003';other_uid uuid:='21000000-0000-4000-8000-000000000002';
 account uuid:='11000000-0000-4000-8000-000000009901';install uuid:=gen_random_uuid();secret text:=repeat('a',64);
 binding public.notification_installations_v2;first_binding public.notification_installations_v2;denied boolean:=false;n integer;
 patient uuid:=gen_random_uuid();target public.notification_delivery_targets_v2;retry public.notification_delivery_targets_v2;step integer;
BEGIN
 SELECT * INTO STRICT first_binding FROM public.register_notification_installation_v2(uid,install,secret,5,account,'synthetic-installation-original','en',repeat('1',64));
 PERFORM pg_temp.require(first_binding.client_revision=5 AND first_binding.is_active AND first_binding.bound_user_uid=uid,
  'authenticated registration binds one installation to its actor and clinic');
 SELECT * INTO STRICT binding FROM public.register_notification_installation_v2(uid,install,secret,5,account,'synthetic-installation-original','en',repeat('1',64));
 PERFORM pg_temp.require(to_jsonb(binding)=to_jsonb(first_binding),'lost registration response replays without another revision or timestamp');
 BEGIN PERFORM public.register_notification_installation_v2(uid,install,secret,5,account,'different','en',repeat('2',64));
 EXCEPTION WHEN check_violation THEN denied:=SQLERRM='notification_registration_identity_mismatch';END;
 PERFORM pg_temp.require(denied,'same revision cannot substitute a different request');denied:=false;
 BEGIN PERFORM public.register_notification_installation_v2(uid,install,secret,4,account,'old','en',repeat('3',64));
 EXCEPTION WHEN check_violation THEN denied:=SQLERRM='notification_registration_stale';END;
 PERFORM pg_temp.require(denied,'late lower revision cannot overwrite a newer registration');denied:=false;
 BEGIN PERFORM public.register_notification_installation_v2(uid,install,repeat('b',64),6,account,'stolen','en',repeat('3',64));
 EXCEPTION WHEN insufficient_privilege THEN denied:=SQLERRM='notification_installation_secret_mismatch';END;
 PERFORM pg_temp.require(denied,'installation UUID alone cannot replace its hardware proof');denied:=false;
 PERFORM public.register_notification_installation_v2(uid,install,secret,6,account,'synthetic-installation-rotated','ar',repeat('4',64));
 PERFORM pg_temp.require((SELECT count(*)=1 FROM public.push_device_tokens WHERE installation_id=install AND is_active)
  AND (SELECT NOT is_active FROM public.push_device_tokens WHERE token='synthetic-installation-original'),
  'rotation retires the previous token but preserves installation identity');
 PERFORM public.register_notification_installation_v2(other_uid,install,secret,7,account,'synthetic-installation-rotated','ar',repeat('5',64));
 PERFORM pg_temp.require((SELECT user_uid=other_uid AND delivery_protocol=2 AND role IS NULL FROM public.push_device_tokens WHERE token='synthetic-installation-rotated'),
  'account switch rebinds the exact token without trusting a role from the client');
 BEGIN PERFORM public.register_notification_installation_v2(uid,install,secret,6,account,'old actor','ar',repeat('6',64));
 EXCEPTION WHEN check_violation THEN denied:=SQLERRM='notification_registration_stale';END;
 PERFORM pg_temp.require(denied,'old actor response arriving after account switch cannot regain the token');denied:=false;
 BEGIN PERFORM public.register_notification_installation_v2(uid,install,secret,8,account,NULL,'ar',repeat('6',64),true);
 EXCEPTION WHEN check_violation THEN denied:=SQLERRM='notification_registration_stale';END;
 PERFORM pg_temp.require(denied,'late old actor logout cannot deactivate the new actor even with a higher revision');denied:=false;
 PERFORM public.register_notification_installation_v2(other_uid,install,secret,8,account,NULL,'ar',repeat('7',64),true);
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM public.push_device_tokens WHERE installation_id=install AND is_active)
  AND (SELECT NOT is_active FROM public.notification_installations_v2 WHERE installation_id=install),
  'verified logout retires all active registrations of the installation');
 PERFORM public.register_notification_installation_v2(uid,install,secret,9,account,'synthetic-installation-restored','en',repeat('8',64));
 UPDATE auth.users SET disabled=true WHERE id=uid;
 BEGIN PERFORM public.register_notification_installation_v2(uid,install,secret,10,account,'disabled','en',repeat('9',64));
 EXCEPTION WHEN insufficient_privilege THEN denied:=SQLERRM='notification_registration_denied';END;
 PERFORM pg_temp.require(denied,'disabled Auth cannot bind a device');denied:=false;
 UPDATE auth.users SET disabled=false WHERE id=uid;
 UPDATE public.accounts SET frozen=true WHERE id=account;
 BEGIN PERFORM public.register_notification_installation_v2(uid,install,secret,10,account,'frozen','en',repeat('9',64));
 EXCEPTION WHEN insufficient_privilege THEN denied:=SQLERRM='notification_registration_denied';END;
 PERFORM pg_temp.require(denied,'frozen clinic cannot receive a new active binding');denied:=false;
 UPDATE public.accounts SET frozen=false WHERE id=account;
 BEGIN PERFORM public.register_notification_installation_v2(uid,install,secret,9007199254740992,account,'overflow','en',repeat('9',64));
 EXCEPTION WHEN invalid_parameter_value THEN denied:=SQLERRM='notification_registration_invalid';END;
 PERFORM pg_temp.require(denied,'revision stays within exact transport integer bounds');denied:=false;
 PERFORM set_config('hasura.user',json_build_object('x-hasura-user-id',uid,'x-hasura-role','user')::text,true);
 BEGIN UPDATE public.push_device_tokens SET account_id=NULL WHERE token='synthetic-installation-restored';
 EXCEPTION WHEN insufficient_privilege THEN denied:=SQLERRM='notification_registration_endpoint_required';END;
 PERFORM pg_temp.require(denied,'ordinary direct token update cannot bypass revision and installation proof');denied:=false;
 BEGIN INSERT INTO public.push_device_tokens(user_uid,platform,token,installation_id,delivery_protocol)
 VALUES(uid,'android','synthetic-forged',gen_random_uuid(),2);
 EXCEPTION WHEN insufficient_privilege THEN denied:=SQLERRM='notification_registration_endpoint_required';END;
 PERFORM pg_temp.require(denied,'ordinary direct insert cannot self-declare protocol2');denied:=false;
 BEGIN DELETE FROM public.push_device_tokens WHERE token='synthetic-installation-restored';
 EXCEPTION WHEN insufficient_privilege THEN denied:=SQLERRM='notification_registration_endpoint_required';END;
 PERFORM pg_temp.require(denied,'ordinary direct delete cannot bypass the protected registration lifecycle');
 PERFORM set_config('hasura.user','{}',true);
 UPDATE public.notification_delivery_control_v2 SET capture_enabled=true,dispatch_enabled=true;
 INSERT INTO public.patients(id,account_id,device_id,local_id,name,doctor_id,registered_at)
 VALUES(patient,account,'installation-policy-fixture',1,'synthetic only','51000000-0000-4000-8000-000000000003','2026-10-23T00:00:00.000001Z');
 SELECT * INTO STRICT target FROM public.claim_notification_targets_v2(gen_random_uuid(),1);
 PERFORM public.finish_notification_target_v2(target.id,target.lease_token,'accepted',NULL,'projects/fixture/messages/known1');
 SELECT count(*) INTO n FROM public.claim_notification_targets_v2(gen_random_uuid(),8);
 PERFORM pg_temp.require(n=0,'known accepted target waits for a device ACK before another attempt');
 UPDATE public.notification_delivery_targets_v2 SET next_attempt_at=clock_timestamp()-interval '1 second' WHERE id=target.id;
 SELECT * INTO STRICT retry FROM public.claim_notification_targets_v2(gen_random_uuid(),1);
 PERFORM pg_temp.require(retry.id=target.id AND retry.ack_nonce=target.ack_nonce AND retry.attempts=2,
  'missing device ACK retries after deadline with the same durable dedup identity');
 FOR step IN 2..8 LOOP
  PERFORM public.finish_notification_target_v2(retry.id,retry.lease_token,'accepted',NULL,'projects/fixture/messages/known'||step);
  UPDATE public.notification_delivery_targets_v2 SET next_attempt_at=clock_timestamp()-interval '1 second' WHERE id=target.id;
  IF step<8 THEN SELECT * INTO STRICT retry FROM public.claim_notification_targets_v2(gen_random_uuid(),1);END IF;
 END LOOP;
 SELECT count(*) INTO n FROM public.claim_notification_targets_v2(gen_random_uuid(),1);
 PERFORM pg_temp.require(n=0 AND (SELECT status='dead' AND attempts=8 AND provider_message_id IS NOT NULL FROM public.notification_delivery_targets_v2 WHERE id=target.id),
  'eight known acceptances without ACK end explicitly without erasing provider evidence');
 PERFORM public.acknowledge_notification_target_v2(target.id,uid,target.ack_nonce);
 PERFORM pg_temp.require((SELECT status='acknowledged' FROM public.notification_delivery_targets_v2 WHERE id=target.id),
  'a late genuine device receipt resolves retry exhaustion');
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
  WHERE p.proname='register_notification_installation_v2' AND a.grantee=0 AND a.privilege_type='EXECUTE'),
  'installation binding grants no PUBLIC execute');
END $$;
SELECT json_build_object('passed',count(*),'cases',json_agg(name ORDER BY name))::text FROM cases;
ROLLBACK;
