\set ON_ERROR_STOP on
BEGIN;
DO $guard$ BEGIN IF current_database() !~ '^elmam_restored_schema_contract_v[0-9]+$' THEN RAISE EXCEPTION 'isolated_restored_fixture_only'; END IF; END; $guard$;
CREATE TEMP TABLE cases(label text PRIMARY KEY);
CREATE FUNCTION pg_temp.check_case(condition boolean, label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF;
  INSERT INTO cases VALUES(label);
END $$;
INSERT INTO auth.roles(role) VALUES('user') ON CONFLICT DO NOTHING;
INSERT INTO auth.users(id,disabled,locale) VALUES('20000000-0000-4000-8000-000000000001',false,'en');
INSERT INTO public.accounts(id,frozen,name) VALUES
  ('10000000-0000-4000-8000-000000000001',false,'synthetic A'),
  ('10000000-0000-4000-8000-000000000002',false,'synthetic B');
INSERT INTO public.account_users(account_id,user_uid,disabled,role)
VALUES('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',false,'owner');
INSERT INTO public.account_feature_permissions(account_id,user_uid,allow_all,can_create,can_update,can_delete)
VALUES('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',true,true,true,true) ON CONFLICT (account_id,user_uid) DO UPDATE SET allow_all=true,can_create=true,can_update=true,can_delete=true;
CREATE FUNCTION pg_temp.request(t text,op text,k bigint,cid text,v text,body jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb; object jsonb;
BEGIN
  object := jsonb_build_object('id',md5(t||':'||k::text)::uuid,
    'account_id','10000000-0000-4000-8000-000000000001',
    'device_id','fixture','local_id',k::text) || body;
  SELECT result_json INTO result FROM public.apply_clinic_sync_atomic(
    '20000000-0000-4000-8000-000000000001',t,op,v,object,
    jsonb_build_object('id',gen_random_uuid(),'client_mutation_id',cid,
      'payload_hash',repeat(md5(object::text||op||coalesce(v,'')),2)),
    jsonb_build_object('id',gen_random_uuid(),'correlation_id',gen_random_uuid()));
  RETURN result;
END $$;
CREATE FUNCTION pg_temp.expect_error(t text,op text,k bigint,cid text,v text,body jsonb,code text,label text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE observed text;
BEGIN
  BEGIN PERFORM pg_temp.request(t,op,k,cid,v,body);
  EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS observed=MESSAGE_TEXT; END;
  PERFORM pg_temp.check_case(observed=code,label);
END $$;
DO $$
DECLARE result jsonb; again jsonb; precise timestamptz; v text; field text; item jsonb;
BEGIN
 result := pg_temp.request('patients','create_patient',1,'precise-patient','0',
   '{"name":"synthetic","registered_at":"2026-10-21T21:15:00.123456Z","register_date":"2026-10-21"}');
 SELECT registered_at,server_version::text INTO precise,v FROM public.patients WHERE local_id=1;
 PERFORM pg_temp.check_case(precise='2026-10-21T21:15:00.123456Z'::timestamptz,'registration retains every microsecond');
 PERFORM pg_temp.check_case((SELECT register_date='2026-10-22'::date FROM public.patients WHERE local_id=1),'civil date derives from clinic zone');
 again := pg_temp.request('patients','create_patient',1,'precise-patient','0',
   '{"name":"synthetic","registered_at":"2026-10-21T21:15:00.123456Z","register_date":"2026-10-21"}');
 PERFORM pg_temp.check_case(again=result AND (SELECT count(*) FROM public.patients)=1,'retry returns identical receipt without duplicating patient');
 result := pg_temp.request('patients','update_patient',1,'rename-patient',v,'{"name":"renamed"}');
 SELECT server_version::text INTO v FROM public.patients WHERE local_id=1;
 PERFORM pg_temp.check_case((SELECT registered_at=precise FROM public.patients WHERE local_id=1),'name-only update preserves exact instant');
 PERFORM pg_temp.expect_error('patients','update_patient',1,'clear-patient',v,'{"registered_at":null}',
   'patient_registration_time_clear_denied','precise instant cannot be silently cleared');
 PERFORM pg_temp.expect_error('patients','create_patient',2,'missing-patient','0','{"name":"missing"}',
   'patient_registration_time_required','new patient requires exact registration');
 PERFORM pg_temp.expect_error('patients','create_patient',3,'naive-patient','0','{"registered_at":"2026-10-22T09:00:00"}',
   'clinic_timestamp_utc_required','new precise registration cannot use device-naive text');
 PERFORM pg_temp.expect_error('patients','create_patient',4,'invalid-patient','0','{"registered_at":"2026-02-30T09:00:00Z"}',
   'clinic_timestamp_invalid','invalid calendar date cannot be normalized');
 PERFORM pg_temp.check_case((SELECT count(*) FROM public.client_mutations)=2 AND
   (SELECT count(*) FROM public.sync_events)=2,'rejected timestamp leaves no receipt or event');
 result := pg_temp.request('patients','update_patient',1,'precise-cutoff',v,'{"registered_at":"2026-10-22T09:00:00.000001Z"}');
 PERFORM pg_temp.check_case((SELECT registered_at>'2026-10-22T09:00:00Z'::timestamptz FROM public.patients WHERE local_id=1),
   'next microsecond remains after exact paid cutoff');
 PERFORM pg_temp.check_case((SELECT clinic_pull_clock_contract='clinic_commit_clock_v1' FROM public.app_server_now),
   'new registration trigger retains pull clock contract');
END $$;
DO $$
DECLARE entity text; fields text[]; field text; body jsonb; observed text; stamp text;
BEGIN
 FOR entity,fields IN SELECT key,ARRAY(SELECT jsonb_array_elements_text(value)) FROM jsonb_each(
  '{"appointments":["appointment_time"],"patients":["registered_at","doctor_reviewed_at"],"returns":["date","attended_at"],"consumptions":["date"],"financial_logs":["timestamp"],"employees_loans":["loan_date_time"],"employees_discounts":["discount_date_time"],"employees_salaries":["payment_date","period_start","period_end"],"purchases":["created_at","date"]}'::jsonb)
 LOOP
  FOREACH field IN ARRAY fields LOOP
   PERFORM public.clinic_validate_temporal_payload(entity,jsonb_build_object(field,'2026-10-22T20:59:59.999999Z'));
   FOREACH stamp IN ARRAY ARRAY['2026-10-22','2026-10-22T23:59:59.999999','2026-10-22T09:00:00.1234567Z','2026-10-22T24:00:00Z','2026-10-22T09:60:00Z','2026-10-22T09:00:60Z'] LOOP
    observed := NULL;
    BEGIN PERFORM public.clinic_validate_temporal_payload(entity,jsonb_build_object(field,stamp));
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS observed=MESSAGE_TEXT; END;
    PERFORM pg_temp.check_case(observed='clinic_timestamp_utc_required',entity||'.'||field||' rejects '||stamp);
   END LOOP;
  END LOOP;
 END LOOP;
 PERFORM public.clinic_validate_temporal_payload('doctors','{"start_time":"09:00","end_time":"17:30"}');
 PERFORM pg_temp.check_case(true,'doctor working hours are not fabricated instants');
END $$;
SELECT json_build_object('passed',count(*),'cases',json_agg(label ORDER BY label)) FROM cases;
ROLLBACK;
