-- Private synthetic fixture only. The original atomic fixture supplies all
-- unrelated sync tables; this is not a replay of the deployed migration chain.
\ir fixtures/clinic_sync_atomic_schema.sql
CREATE TABLE public.elmam_doctor_catalog_fixture_marker(value text PRIMARY KEY);
INSERT INTO public.elmam_doctor_catalog_fixture_marker VALUES('local_doctor_catalog_20261019');
CREATE FUNCTION public.fixture_uuid(value integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT ('00000000-0000-4000-8000-'||lpad(value::text,12,'0'))::uuid
$$;
ALTER TABLE public.doctors ALTER COLUMN employee_id TYPE uuid USING employee_id::uuid;
ALTER TABLE public.doctors ALTER COLUMN user_uid TYPE uuid USING user_uid::uuid;
ALTER TABLE public.service_doctor_share ALTER COLUMN service_id TYPE uuid USING service_id::uuid;
ALTER TABLE public.service_doctor_share ALTER COLUMN doctor_id TYPE uuid USING doctor_id::uuid;
\ir ../nhost/migrations/default/20260615120000_sync_guardrails/up.sql
\ir ../nhost/migrations/default/20260722006000_correlated_domain_read_authorization/up.sql
CREATE VIEW public.active_superadmin_identity WITH(security_barrier=true) AS
SELECT sa.user_uid FROM public.super_admins sa JOIN auth.users u ON u.id=sa.user_uid
WHERE sa.disabled IS DISTINCT FROM true AND u.disabled IS DISTINCT FROM true;
INSERT INTO public.accounts(id) VALUES(public.fixture_uuid(1)),(public.fixture_uuid(2));
INSERT INTO auth.users(id,disabled) SELECT public.fixture_uuid(n),n=17 FROM generate_series(11,21) n;
INSERT INTO public.account_users(account_id,user_uid,role,disabled)
SELECT public.fixture_uuid(CASE WHEN n=16 THEN 2 ELSE 1 END),public.fixture_uuid(n),'employee',n=18
FROM generate_series(11,19) n;
INSERT INTO public.super_admins(user_uid) VALUES(public.fixture_uuid(21));
INSERT INTO public.account_feature_permissions(account_id,user_uid,allowed_features,allow_all,can_create,can_update,can_delete)
SELECT public.fixture_uuid(CASE WHEN n=16 THEN 2 ELSE 1 END),public.fixture_uuid(n),
  CASE WHEN n IN(14,18) THEN ARRAY['patients.new','patients.list']
    WHEN n=13 THEN ARRAY['lab_radiology']
    WHEN n=15 THEN ARRAY['employees','lab_radiology'] ELSE ARRAY['employees'] END,
  false,n NOT IN(14,18),n NOT IN(14,18),n NOT IN(14,18)
FROM generate_series(11,19) n;
INSERT INTO public.doctors(id,account_id,device_id,local_id,name,specialization)
VALUES(public.fixture_uuid(31),public.fixture_uuid(1),'seed',31,'Fixture doctor','General'),
  (public.fixture_uuid(32),public.fixture_uuid(2),'seed',32,'Foreign fixture doctor','General');
INSERT INTO public.medical_services(id,account_id,device_id,local_id,name,cost,cost_minor,service_type)
SELECT public.fixture_uuid(n),public.fixture_uuid(CASE WHEN n=46 THEN 2 ELSE 1 END),'seed',n,'Fixture service '||n,
  '123.45',12345,CASE n WHEN 41 THEN 'doctorGeneral' WHEN 42 THEN 'doctor' WHEN 43 THEN 'طبيب'
  WHEN 44 THEN 'lab' WHEN 45 THEN 'radiology' ELSE 'doctorGeneral' END FROM generate_series(41,46) n;
INSERT INTO public.service_doctor_share(id,account_id,device_id,local_id,service_id,doctor_id,share_percentage,tower_share_percentage,is_hidden)
VALUES(public.fixture_uuid(61),public.fixture_uuid(1),'seed',61,public.fixture_uuid(41),public.fixture_uuid(31),'25','75','false'),
  (public.fixture_uuid(62),public.fixture_uuid(1),'seed',62,public.fixture_uuid(44),public.fixture_uuid(31),'25','75','false'),
  (public.fixture_uuid(63),public.fixture_uuid(2),'seed',63,public.fixture_uuid(46),public.fixture_uuid(32),'25','75','false'),
  (public.fixture_uuid(64),public.fixture_uuid(1),'seed',64,public.fixture_uuid(46),public.fixture_uuid(31),'25','75','false'),
  (public.fixture_uuid(65),public.fixture_uuid(1),'seed',65,public.fixture_uuid(41),public.fixture_uuid(32),'25','75','false');
-- The real composite constraints are NOT VALID and preserve legacy rows.
-- Deliberately corrupt historical rows above must not enter reception reads.
ALTER TABLE public.service_doctor_share ADD CONSTRAINT service_share_service_same_account_fk
  FOREIGN KEY(account_id,service_id) REFERENCES public.medical_services(account_id,id) NOT VALID,
  ADD CONSTRAINT service_share_doctor_same_account_fk
  FOREIGN KEY(account_id,doctor_id) REFERENCES public.doctors(account_id,id) NOT VALID;
CREATE ROLE elmam_doctor_catalog_client NOLOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT;
