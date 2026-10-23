BEGIN;
SET LOCAL lock_timeout = '5s';
DO $guard$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.apply_clinic_sync_atomic(uuid,text,text,text,jsonb,jsonb,jsonb)'::regprocedure) NOT IN ('9556563e32b2009d939d2bc495180c81','a644fa90be1279c9ef5ec33b27ec3248') THEN RAISE EXCEPTION 'unexpected_atomic_sync_body'; END IF; END; $guard$;


-- The existing DATE is a clinic-day projection. Do not convert experimental
-- historical DATE values into an invented midnight instant.
ALTER TABLE public.patients ADD COLUMN IF NOT EXISTS registered_at timestamptz;
COMMENT ON COLUMN public.patients.registered_at IS
  'Exact clinical registration instant. NULL means no recorded precise time; never inferred from register_date.';

CREATE OR REPLACE FUNCTION public.tg_patient_registration_time()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $body$
BEGIN
  IF TG_OP='INSERT' AND NEW.registered_at IS NULL THEN
    RAISE EXCEPTION 'patient_registration_time_required' USING ERRCODE='22023';
  END IF;
  IF TG_OP='UPDATE' AND OLD.registered_at IS NOT NULL AND NEW.registered_at IS NULL THEN
    RAISE EXCEPTION 'patient_registration_time_clear_denied' USING ERRCODE='22023';
  END IF;
  IF NEW.registered_at IS NOT NULL THEN
    NEW.register_date := (NEW.registered_at AT TIME ZONE 'Asia/Aden')::date;
  END IF;
  RETURN NEW;
END;
$body$;
REVOKE ALL ON FUNCTION public.tg_patient_registration_time() FROM PUBLIC;
DROP TRIGGER IF EXISTS clinic_patient_registration_time ON public.patients;
CREATE TRIGGER clinic_patient_registration_time BEFORE INSERT OR UPDATE
  ON public.patients FOR EACH ROW EXECUTE FUNCTION public.tg_patient_registration_time();

CREATE OR REPLACE FUNCTION public.clinic_validate_temporal_payload(entity text, object jsonb)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $body$
DECLARE
  fields constant jsonb := '{"appointments":["appointment_time"],"patients":["registered_at","doctor_reviewed_at"],"returns":["date","attended_at"],"consumptions":["date"],"financial_logs":["timestamp"],"employees_loans":["loan_date_time"],"employees_discounts":["discount_date_time"],"employees_salaries":["payment_date","period_start","period_end"],"purchases":["created_at","date"]}'::jsonb;
  field text;
  value text;
  parsed timestamptz;
BEGIN
  FOR field IN SELECT jsonb_array_elements_text(COALESCE(fields->entity,'[]'::jsonb)) LOOP
    IF NOT object ? field OR object->field='null'::jsonb THEN CONTINUE; END IF;
    value := object->>field;
    IF jsonb_typeof(object->field)<>'string' OR value !~
      '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.][0-9]{1,6})?Z$' THEN
      RAISE EXCEPTION 'clinic_timestamp_utc_required' USING ERRCODE='22023';
    END IF;
    BEGIN
      parsed := value::timestamptz;
    EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
      RAISE EXCEPTION 'clinic_timestamp_invalid' USING ERRCODE='22023';
    END;
  END LOOP;
END;
$body$;
REVOKE ALL ON FUNCTION public.clinic_validate_temporal_payload(text,jsonb) FROM PUBLIC;

-- The following reviewed RPC replacement changes only the patient allow-list
-- and validation of new requests. Cached receipts return before validation;
-- their identity and committed response remain unchanged.
CREATE OR REPLACE FUNCTION public.apply_clinic_sync_atomic(
  p_actor uuid, p_table text, p_operation text, p_expected_version text,
  p_object jsonb, p_receipt jsonb, p_event jsonb
) RETURNS SETOF public.client_mutations
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
DECLARE
  contract constant jsonb := '{"item_types":{"columns":["name"],"domain":"reference","features":"repository"},"items":{"columns":["type_id","name","price","price_minor","created_at"],"domain":"inventory","features":"repository"},"drugs":{"columns":["name","notes","created_at"],"domain":"reference","features":"prescriptions"},"medical_services":{"columns":["name","cost","cost_minor","service_type"],"domain":"reference","features":"lab_radiology"},"consumption_types":{"columns":["type"],"domain":"reference","features":"repository"},"employees":{"columns":["name","identity_number","phone_number","job_title","address","marital_status","basic_salary","basic_salary_minor","final_salary","final_salary_minor","is_doctor","user_uid"],"domain":"staff","features":"employees"},"doctors":{"columns":["employee_id","user_uid","name","specialization","phone_number","start_time","end_time","print_counter"],"domain":"staff","features":"employees"},"service_doctor_share":{"columns":["service_id","doctor_id","share_percentage","tower_share_percentage","is_hidden"],"domain":"staff","features":"lab_radiology"},"patients":{"columns":["name","age","diagnosis","paid_amount","paid_amount_minor","remaining","remaining_minor","register_date","registered_at","phone_number","health_status","preferences","collateral","doctor_id","doctor_name","doctor_specialization","notes","service_type","service_id","service_name","service_cost","service_cost_minor","doctor_share","doctor_share_minor","doctor_input","doctor_input_minor","tower_share","tower_share_minor","department_share","department_share_minor","doctor_review_pending","doctor_reviewed_at"],"domain":"clinical","features":{"create":"patients.new","update":"patients.list","delete":"patients.list"}},"patient_services":{"columns":["patient_id","service_id","service_name","service_cost","service_cost_minor"],"domain":"clinical","features":"patients.list"},"returns":{"columns":["date","patient_name","phone_number","diagnosis","remaining","remaining_minor","age","doctor","notes","is_attended","attended_at"],"domain":"clinical","features":"returns"},"appointments":{"columns":["patient_id","doctor_id","appointment_time","status","notes"],"domain":"clinical","features":"patients.list"},"prescriptions":{"columns":["patient_id","doctor_id","record_date","created_at"],"domain":"clinical","features":"prescriptions"},"prescription_items":{"columns":["prescription_id","drug_id","days","times_per_day"],"domain":"clinical","features":"prescriptions"},"consumptions":{"columns":["patient_id","item_id","quantity","date","amount","amount_minor","unit_price_snapshot","unit_price_minor","note"],"domain":"inventory","features":"repository"},"purchases":{"columns":["item_id","item_name_snapshot","item_type_name_snapshot","quantity","total","amount_minor","unit_price_snapshot","unit_price_minor","created_at","date"],"domain":"inventory","features":"repository"},"alert_settings":{"columns":["item_id","item_uuid","threshold","is_enabled","last_triggered","created_at","notify_time"],"domain":"inventory","features":"repository"},"employees_loans":{"columns":["employee_id","loan_date_time","final_salary","final_salary_minor","ratio_sum","ratio_sum_minor","loan_amount","loan_amount_minor","leftover","leftover_minor"],"domain":"finance","features":"payments"},"employees_salaries":{"columns":["employee_id","year","month","final_salary","final_salary_minor","ratio_sum","ratio_sum_minor","total_loans","total_loans_minor","total_discounts","total_discounts_minor","net_pay","net_pay_minor","is_paid","payment_date","period_start","period_end"],"domain":"finance","features":"payments"},"employees_discounts":{"columns":["employee_id","discount_date_time","amount","amount_minor","notes"],"domain":"finance","features":"payments"},"complaints":{"columns":["subject","message","status","reply_message","replied_at","replied_by","handled_by","handled_at","created_at"],"domain":"clinical","features":"patients.questions"},"financial_logs":{"columns":["transaction_type","operation","amount","amount_minor","employee_id","patient_id","description","modification_details","timestamp"],"domain":"finance","features":"payments"}}'::jsonb;
  spec jsonb := contract->p_table;
  account uuid := (p_object->>'account_id')::uuid;
  row_id uuid := (p_object->>'id')::uuid;
  origin text := p_object->>'device_id';
  local_key bigint := (p_object->>'local_id')::bigint;
  cid text := p_receipt->>'client_mutation_id';
  expected bigint;
  deleted boolean := lower(p_operation) ~ '(delete|reverse|disable|archive)';
  action text;
  feature_name text;
  required_features text[];
  feature public.account_feature_permissions;
  super_actor boolean;
  prior jsonb;
  committed jsonb;
  cached public.client_mutations;
  receipt public.client_mutations;
  object jsonb;
  result jsonb;
  columns_sql text;
  values_sql text;
  updates_sql text;
  identity_account uuid;
BEGIN
  IF spec IS NULL OR account IS NULL OR row_id IS NULL OR p_actor IS NULL
    OR COALESCE(origin,'')='' OR local_key IS NULL OR local_key<=0
    OR COALESCE(btrim(cid),'')='' OR COALESCE(btrim(p_operation),'')=''
    OR COALESCE(p_receipt->>'payload_hash','') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'sync_atomic_request_invalid' USING ERRCODE='22023';
  END IF;
  IF p_expected_version IS NOT NULL THEN
    IF p_expected_version !~ '^(0|[1-9][0-9]{0,18})$'
      OR p_expected_version::numeric > 9223372036854775807 THEN
      RAISE EXCEPTION 'sync_expected_version_invalid' USING ERRCODE='22023';
    END IF;
    expected := p_expected_version::bigint;
  END IF;
  PERFORM 1 FROM auth.users WHERE id=p_actor AND disabled IS DISTINCT FROM true FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sync_atomic_denied' USING ERRCODE='42501'; END IF;
  PERFORM 1 FROM public.accounts WHERE id=account AND frozen IS DISTINCT FROM true FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sync_atomic_denied' USING ERRCODE='42501'; END IF;
  SELECT true INTO super_actor FROM public.super_admins
    WHERE user_uid=p_actor AND disabled IS DISTINCT FROM true FOR SHARE;
  IF super_actor IS DISTINCT FROM true THEN
    PERFORM 1 FROM public.account_users WHERE account_id=account AND user_uid=p_actor
      AND disabled IS DISTINCT FROM true FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'sync_atomic_denied' USING ERRCODE='42501'; END IF;
    SELECT * INTO feature FROM public.account_feature_permissions
      WHERE account_id=account AND user_uid=p_actor FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'sync_atomic_denied' USING ERRCODE='42501'; END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('clinic-receipt:'||account::text||':'||cid,0));
  SELECT * INTO cached FROM public.client_mutations
    WHERE account_id=account AND client_mutation_id=cid FOR UPDATE;
  IF FOUND THEN
    IF cached.payload_hash IS DISTINCT FROM p_receipt->>'payload_hash'
      OR cached.operation_type IS DISTINCT FROM p_operation
      OR cached.result_json->'data'->>'entity_table' IS DISTINCT FROM p_table
      OR cached.result_json->'data'->>'remote_id' IS DISTINCT FROM row_id::text THEN
      RAISE EXCEPTION 'idempotency_payload_mismatch' USING ERRCODE='23514';
    END IF;
    IF cached.result_json IS NULL THEN
      RAISE EXCEPTION 'mutation_in_progress' USING ERRCODE='23514';
    END IF;
    action := CASE WHEN deleted THEN 'delete'
      WHEN lower(p_operation) ~ '^(create|add|insert)' THEN 'create' ELSE 'update' END;
  ELSE
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'clinic-origin:'||account::text||':'||p_table||':'||origin||':'||local_key::text,0));
    EXECUTE format('SELECT to_jsonb(r) FROM public.%I r
      WHERE account_id=$1 AND device_id=$2 AND local_id=$3 FOR UPDATE',p_table)
      INTO prior USING account,origin,local_key;
    IF prior IS NOT NULL AND (prior->>'id')::uuid <> row_id THEN
      RAISE EXCEPTION 'sync_identity_mismatch' USING ERRCODE='23514';
    END IF;
    EXECUTE format('SELECT account_id FROM public.%I WHERE id=$1',p_table)
      INTO identity_account USING row_id;
    IF identity_account IS NOT NULL AND identity_account <> account THEN
      RAISE EXCEPTION 'foreign_sync_identity' USING ERRCODE='42501';
    ELSIF identity_account IS NOT NULL AND prior IS NULL THEN
      RAISE EXCEPTION 'sync_identity_mismatch' USING ERRCODE='23514';
    END IF;
    action := CASE WHEN deleted THEN 'delete'
      WHEN prior IS NULL THEN 'create' ELSE 'update' END;
  END IF;
  feature_name := CASE WHEN jsonb_typeof(spec->'features')='string'
    THEN spec->>'features' ELSE spec->'features'->>action END;
  -- The two catalog tables override the historical static feature in spec.
  required_features := CASE WHEN p_table IN ('medical_services','service_doctor_share')
    THEN public.doctor_service_sync_features(p_table,account,prior,p_object,cached.id IS NOT NULL OR deleted)
    ELSE ARRAY[feature_name] END;
  IF super_actor IS DISTINCT FROM true AND (
    CASE action WHEN 'create' THEN feature.can_create
      WHEN 'delete' THEN feature.can_delete ELSE feature.can_update END IS DISTINCT FROM true
    OR NOT (COALESCE(feature.allow_all,false)
      OR COALESCE(required_features <@ feature.allowed_features,false))) THEN
    RAISE EXCEPTION 'sync_atomic_denied' USING ERRCODE='42501';
  END IF;
  IF cached.id IS NOT NULL THEN RETURN NEXT cached; RETURN; END IF;

  IF prior IS NULL THEN
    IF deleted THEN RAISE EXCEPTION 'sync_identity_missing' USING ERRCODE='23514'; END IF;
    IF expected IS NOT NULL AND expected<>0 THEN
      RAISE EXCEPTION 'sync_version_conflict' USING ERRCODE='23514';
    END IF;
  ELSE
    IF expected IS NULL THEN
      -- Preserve unknown legacy intents for explicit reconciliation; do not
      -- invent a baseline from the current server row and overwrite a rival.
      RAISE EXCEPTION 'sync_version_unknown' USING ERRCODE='23514';
    END IF;
    IF expected IS DISTINCT FROM (prior->>'server_version')::bigint THEN
      RAISE EXCEPTION 'sync_version_conflict' USING ERRCODE='23514';
    END IF;
    IF (prior->>'is_deleted')::boolean IS TRUE AND NOT deleted THEN
      RAISE EXCEPTION 'sync_record_deleted' USING ERRCODE='23514';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_object) k
    WHERE k <> ALL(ARRAY['id','account_id','device_id','local_id','updated_at',
      'client_mutation_id','updated_by_user_id','is_deleted','deleted_at',
      'deleted_by_user_id','deletion_client_mutation_id'])
      AND NOT (spec->'columns' ? k)) THEN
    RAISE EXCEPTION 'sync_atomic_request_invalid' USING ERRCODE='22023';
  END IF;
  object := p_object - ARRAY['updated_at','updated_by_user_id','client_mutation_id',
    'is_deleted','deleted_at','deleted_by_user_id','deletion_client_mutation_id'];
  IF deleted THEN
    -- Delete authority cannot be used to rewrite business fields or amounts.
    object := object - ARRAY(SELECT jsonb_array_elements_text(spec->'columns'));
  END IF;
  PERFORM public.clinic_validate_temporal_payload(p_table,object);
  object := object || jsonb_build_object('updated_at',now(),
    'client_mutation_id',cid,'updated_by_user_id',p_actor);
  IF deleted THEN
    object := object || jsonb_build_object('is_deleted',true,'deleted_at',now(),
      'deleted_by_user_id',p_actor,'deletion_client_mutation_id',cid);
  END IF;
  SELECT string_agg(quote_ident(k),',' ORDER BY k),
    string_agg('v.'||quote_ident(k),',' ORDER BY k),
    string_agg(quote_ident(k)||'=v.'||quote_ident(k),',' ORDER BY k)
      FILTER (WHERE k<>ALL(ARRAY['id','account_id','device_id','local_id']))
    INTO columns_sql,values_sql,updates_sql FROM jsonb_object_keys(object) k;
  IF prior IS NULL THEN
    EXECUTE format('INSERT INTO public.%I AS r(%s)
      SELECT %s FROM jsonb_populate_record(NULL::public.%I,$1) v
      RETURNING to_jsonb(r)',p_table,columns_sql,values_sql,p_table)
      INTO committed USING object;
  ELSE
    EXECUTE format('UPDATE public.%I AS r SET %s
      FROM jsonb_populate_record(NULL::public.%I,$1) v
      WHERE r.id=$2 AND r.account_id=$3 AND r.server_version=$4
      RETURNING to_jsonb(r)',p_table,updates_sql,p_table)
      INTO committed USING object,row_id,account,expected;
    IF committed IS NULL THEN
      RAISE EXCEPTION 'sync_version_conflict' USING ERRCODE='23514';
    END IF;
  END IF;
  -- Older money/ledger triggers can derive a different minor value through a
  -- floating-point projection. Reject the whole transaction instead of
  -- acknowledging a different amount or fabricating a known historical value.
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(object) k
    WHERE right(k,6)='_minor'
      AND object->>k IS DISTINCT FROM committed->>k) THEN
    RAISE EXCEPTION 'sync_money_mismatch' USING ERRCODE='23514';
  END IF;
  -- Exact bigint text in JSON, including monetary columns and origin/version.
  SELECT jsonb_object_agg(k,CASE WHEN v<>'null'::jsonb AND
    (k IN ('local_id','server_version') OR k LIKE '%\_minor' ESCAPE '\')
    THEN to_jsonb(v#>>'{}') ELSE v END)
    INTO committed FROM jsonb_each(committed) e(k,v);
  INSERT INTO public.sync_events(id,account_id,domain,entity_table,entity_id,
    operation_type,actor_user_id,client_mutation_id,correlation_id)
  VALUES ((p_event->>'id')::uuid,account,spec->>'domain',p_table,row_id,
    p_operation,p_actor,cid,(p_event->>'correlation_id')::uuid);
  result := jsonb_build_object('success',true,'operation',p_operation,
    'server_timestamp',committed->>'updated_at','data',jsonb_build_object(
      'account_id',account,'entity_table',p_table,'client_mutation_id',cid,
      'remote_id',row_id,'server_version',committed->>'server_version',
      'sync_event_id',(p_event->>'id')::uuid,'server_row',jsonb_build_object(
        'id',committed->'id','account_id',committed->'account_id',
        'device_id',committed->'device_id','local_id',committed->'local_id',
        'server_version',committed->'server_version','updated_at',committed->'updated_at',
        'client_mutation_id',committed->'client_mutation_id','is_deleted',committed->'is_deleted')));
  INSERT INTO public.client_mutations(id,account_id,client_mutation_id,operation_type,
    actor_user_id,payload_hash,correlation_id,result_json,completed_at)
  VALUES ((p_receipt->>'id')::uuid,account,cid,p_operation,p_actor,
    p_receipt->>'payload_hash',(p_event->>'correlation_id')::uuid,result,now())
  RETURNING * INTO receipt;
  RETURN NEXT receipt;
END;
$function$;
REVOKE ALL ON FUNCTION public.apply_clinic_sync_atomic(uuid,text,text,text,jsonb,jsonb,jsonb) FROM PUBLIC;
COMMIT;
