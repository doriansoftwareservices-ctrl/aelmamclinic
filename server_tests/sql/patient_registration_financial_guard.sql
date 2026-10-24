BEGIN;
SET LOCAL statement_timeout='30s';
DO $$ BEGIN IF current_database()<>'elmam_notification_source_v2_v1' THEN RAISE EXCEPTION 'owned_fixture_only';END IF;END $$;
CREATE TEMP TABLE cases(name text PRIMARY KEY) ON COMMIT DROP;
CREATE FUNCTION pg_temp.require(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'failed: %',label;END IF;INSERT INTO cases VALUES(label);END $$;
CREATE FUNCTION pg_temp.denied(command text,code text,label text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE rejected boolean:=false;
BEGIN
 BEGIN EXECUTE command;EXCEPTION WHEN check_violation THEN rejected:=SQLERRM=code;END;
 PERFORM pg_temp.require(rejected,label);
END $$;
CREATE TEMP TABLE legacy_patients (LIKE public.patients INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
DO $$
DECLARE account uuid:='11000000-0000-4000-8000-000000009901';
 emp uuid:=gen_random_uuid();doc uuid:=gen_random_uuid();sal uuid:=gen_random_uuid();patient uuid:=gen_random_uuid();
 emp2 uuid:=gen_random_uuid();doc2 uuid:=gen_random_uuid();sal2 uuid:=gen_random_uuid();
 old_patient jsonb;old_salary jsonb;old_clock timestamptz;legacy uuid:=gen_random_uuid();
BEGIN
 UPDATE public.notification_delivery_control_v2 SET capture_enabled=false,dispatch_enabled=false;
 INSERT INTO public.employees(id,account_id,device_id,local_id,name,is_doctor)
 VALUES(emp,account,'financial-guard-'||emp,1,'synthetic guard',true),(emp2,account,'financial-guard-'||emp2,1,'synthetic other',true);
 INSERT INTO public.doctors(id,account_id,device_id,local_id,name,employee_id)
 VALUES(doc,account,'financial-guard-'||doc,1,'synthetic guard',emp),(doc2,account,'financial-guard-'||doc2,1,'synthetic other',emp2);
 INSERT INTO public.employees_salaries(id,account_id,device_id,local_id,employee_id,is_paid,payment_date,period_end)
 VALUES(sal,account,'financial-guard-'||sal,1,emp,true,'2026-10-24T12:00:00Z','2026-10-24T12:00:00Z');
 INSERT INTO public.patients(id,account_id,device_id,local_id,name,doctor_id,registered_at)
 VALUES(patient,account,'financial-guard-'||patient,1,'synthetic guard',doc,'2026-10-24T11:00:00Z');
 SELECT to_jsonb(p) INTO old_patient FROM public.patients p WHERE id=patient;
 SELECT to_jsonb(s) INTO old_salary FROM public.employees_salaries s WHERE id=sal;
 SELECT last_at INTO old_clock FROM public.clinic_pull_clocks WHERE account_id=account;
 PERFORM pg_temp.denied(format('UPDATE public.patients SET registered_at=%L WHERE id=%L','2026-10-24T12:00:00.000001Z',patient),
  'patient_registration_paid_period_locked','already paid visit cannot move forward to be paid twice');
 PERFORM pg_temp.require((SELECT to_jsonb(p)=old_patient FROM public.patients p WHERE id=patient)
  AND (SELECT to_jsonb(s)=old_salary FROM public.employees_salaries s WHERE id=sal)
  AND (SELECT last_at=old_clock FROM public.clinic_pull_clocks WHERE account_id=account),
  'rejected update rolls back patient salary and allocated pull clock');
 PERFORM pg_temp.denied(format('UPDATE public.patients SET doctor_id=%L WHERE id=%L',doc2,patient),
  'patient_registration_paid_period_locked','changing only doctor cannot detach a visit from its paid history');
 UPDATE public.patients SET registered_at='2026-10-24T14:00:00+03:00',notes='metadata' WHERE id=patient;
 PERFORM pg_temp.require((SELECT notes='metadata' AND registered_at='2026-10-24T11:00:00Z' FROM public.patients WHERE id=patient),
  'equivalent offset and metadata edit preserve the actual paid instant');
 UPDATE public.employees_salaries SET is_paid=false WHERE id=sal;
 UPDATE public.patients SET registered_at='2026-10-24T12:00:00.000001Z' WHERE id=patient;
 UPDATE public.employees_salaries SET is_paid=true WHERE id=sal;
 PERFORM pg_temp.denied(format('UPDATE public.patients SET registered_at=%L WHERE id=%L','2026-10-24T12:00:00Z',patient),
  'patient_registration_paid_period_locked','unpaid next microsecond cannot move backward into paid coverage');
 UPDATE public.patients SET registered_at='2026-10-24T13:00:00Z' WHERE id=patient;
 PERFORM pg_temp.require((SELECT registered_at='2026-10-24T13:00:00Z' FROM public.patients WHERE id=patient),
  'correction wholly after the paid cutoff remains available');
 UPDATE public.employees_salaries SET payment_date='2026-10-24T14:00:00Z' WHERE id=sal;
 UPDATE public.patients SET registered_at='2026-10-24T13:30:00Z' WHERE id=patient;
 PERFORM pg_temp.require((SELECT registered_at='2026-10-24T13:30:00Z' FROM public.patients WHERE id=patient),
  'explicit period end wins over later cash payment time');
 UPDATE public.employees_salaries SET is_paid=false WHERE id=sal;
 UPDATE public.patients SET registered_at='2026-10-24T10:00:00Z' WHERE id=patient;
 PERFORM pg_temp.require((SELECT registered_at='2026-10-24T10:00:00Z' FROM public.patients WHERE id=patient),
  'unpaid salary does not lock a correction');
 UPDATE public.employees_salaries SET is_paid=true,is_deleted=true WHERE id=sal;
 UPDATE public.patients SET registered_at='2026-10-24T11:00:00Z' WHERE id=patient;
 PERFORM pg_temp.require((SELECT registered_at='2026-10-24T11:00:00Z' FROM public.patients WHERE id=patient),
  'deleted salary follows the same exclusion as payroll accrual');
 UPDATE public.employees_salaries SET is_deleted=false WHERE id=sal;
 UPDATE public.employees SET is_deleted=true WHERE id=emp;
 PERFORM pg_temp.denied(format('UPDATE public.patients SET registered_at=%L WHERE id=%L','2026-10-24T13:00:00Z',patient),
  'patient_registration_paid_period_locked','archived employee cannot unlock paid time');
 UPDATE public.employees SET is_deleted=false WHERE id=emp;
 UPDATE public.employees_salaries SET payment_date=NULL WHERE id=sal;
 PERFORM pg_temp.denied(format('UPDATE public.patients SET registered_at=%L WHERE id=%L','2026-10-24T13:00:00Z',patient),
  'patient_registration_financial_review_required','unknown paid instant fails closed with a review code');
 UPDATE public.employees_salaries SET payment_date='2026-10-24T14:00:00Z',is_paid=false WHERE id=sal;
 UPDATE public.patients SET registered_at='2026-10-24T13:00:00Z' WHERE id=patient;
 INSERT INTO public.employees_salaries(id,account_id,device_id,local_id,employee_id,is_paid,payment_date,period_end)
 VALUES(sal2,account,'financial-guard-'||sal2,1,emp2,true,'2026-10-24T15:00:00Z','2026-10-24T15:00:00Z');
 PERFORM pg_temp.denied(format('UPDATE public.patients SET doctor_id=%L,registered_at=%L WHERE id=%L',doc2,'2026-10-24T14:00:00Z',patient),
  'patient_registration_paid_period_locked','new doctor paid cutoff is checked as well as the former doctor');
 UPDATE public.doctors SET employee_id=NULL,user_uid=NULL WHERE id=doc;
 PERFORM pg_temp.denied(format('UPDATE public.patients SET registered_at=%L WHERE id=%L','2026-10-24T14:00:00Z',patient),
  'patient_registration_financial_review_required','missing payroll identity requires review rather than assuming unpaid');
 UPDATE public.employees_salaries SET is_paid=false WHERE id IN (sal,sal2);
 UPDATE public.patients SET registered_at='2026-10-24T14:00:00Z' WHERE id=patient;
 PERFORM pg_temp.require((SELECT registered_at='2026-10-24T14:00:00Z' FROM public.patients WHERE id=patient),
  'unbound doctor remains editable before the clinic has any paid salary');
 UPDATE public.doctors SET employee_id=emp WHERE id=doc;
 UPDATE public.employees_salaries SET is_paid=true WHERE id=sal;
 INSERT INTO legacy_patients(id,account_id,device_id,local_id,name,doctor_id,register_date,registered_at)
 VALUES(legacy,account,'financial-legacy-'||legacy,1,'synthetic retained date',doc,'2026-10-24',NULL);
 EXECUTE 'CREATE TRIGGER legacy_financial_time AFTER UPDATE ON legacy_patients FOR EACH ROW EXECUTE FUNCTION public.guard_patient_registration_financial_time()';
 PERFORM pg_temp.denied(format('UPDATE legacy_patients SET registered_at=%L WHERE id=%L','2026-10-24T14:00:00Z',legacy),
  'patient_registration_paid_period_locked','retained civil input helper cannot invent an unpaid side of the cutoff');
 PERFORM pg_temp.require((SELECT clinic_pull_clock_contract='clinic_commit_clock_v1' FROM public.app_server_now),
  'AFTER guard preserves the exact existing commit clock capability');
 PERFORM pg_temp.require(NOT EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
  WHERE p.oid='public.guard_patient_registration_financial_time()'::regprocedure AND a.grantee=0 AND a.privilege_type='EXECUTE'),
  'private financial helper grants no PUBLIC execute');
 PERFORM pg_temp.require((SELECT tgtype=17 FROM pg_trigger WHERE tgrelid='public.patients'::regclass AND tgname='patient_registration_financial_time'),
  'actual patient guard is AFTER UPDATE row trigger');
END $$;
SELECT json_build_object('passed',count(*),'cases',json_agg(name ORDER BY name)) FROM cases;
ROLLBACK;
