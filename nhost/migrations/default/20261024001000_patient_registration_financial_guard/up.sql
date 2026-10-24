BEGIN;
SET LOCAL lock_timeout='5s';

-- AFTER the existing BEFORE clock trigger has acquired the clinic clock row.
-- Salary and patient writers therefore share commit serialization without
-- changing the advertised pull-clock body or its last-BEFORE-trigger contract.
CREATE FUNCTION public.guard_patient_registration_financial_time()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public AS $body$
DECLARE doctor_key uuid;doctor_row public.doctors;employee_key uuid;
 employee_keys uuid[];cutoff timestamptz;invalid_coverage boolean;
BEGIN
 IF OLD.registered_at IS NOT DISTINCT FROM NEW.registered_at AND OLD.doctor_id IS NOT DISTINCT FROM NEW.doctor_id THEN RETURN NULL; END IF;
 IF OLD.account_id IS DISTINCT FROM NEW.account_id THEN
  RAISE EXCEPTION 'patient_registration_financial_review_required' USING ERRCODE='23514';
 END IF;
 FOR doctor_key IN SELECT DISTINCT id FROM (VALUES(OLD.doctor_id),(NEW.doctor_id)) d(id) WHERE id IS NOT NULL LOOP
  SELECT * INTO doctor_row FROM public.doctors WHERE id=doctor_key AND account_id=OLD.account_id;
  IF NOT FOUND THEN
   RAISE EXCEPTION 'patient_registration_financial_review_required' USING ERRCODE='23514';
  END IF;
  employee_key:=NULL;
  IF doctor_row.employee_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.employees WHERE id=doctor_row.employee_id AND account_id=OLD.account_id) THEN
   employee_key:=doctor_row.employee_id;
  ELSIF doctor_row.user_uid IS NOT NULL THEN
   SELECT array_agg(id) INTO employee_keys FROM (SELECT id FROM public.employees
    WHERE account_id=OLD.account_id AND user_uid=doctor_row.user_uid ORDER BY id LIMIT 2) e;
   IF cardinality(employee_keys)>1 THEN
    RAISE EXCEPTION 'patient_registration_financial_review_required' USING ERRCODE='23514';
   END IF;
   employee_key:=employee_keys[1];
  END IF;
  IF employee_key IS NULL THEN
   IF EXISTS(SELECT 1 FROM public.employees_salaries WHERE account_id=OLD.account_id AND is_paid=true AND is_deleted IS DISTINCT FROM true) THEN
    RAISE EXCEPTION 'patient_registration_financial_review_required' USING ERRCODE='23514';
   END IF;
   CONTINUE;
  END IF;
  SELECT max(COALESCE(period_end,payment_date)),bool_or(payment_date IS NULL OR period_end>payment_date)
   INTO cutoff,invalid_coverage FROM public.employees_salaries
   WHERE account_id=OLD.account_id AND employee_id=employee_key AND is_paid=true AND is_deleted IS DISTINCT FROM true;
  IF invalid_coverage THEN
   RAISE EXCEPTION 'patient_registration_financial_review_required' USING ERRCODE='23514';
  END IF;
  IF cutoff IS NOT NULL AND (OLD.registered_at IS NULL OR NEW.registered_at IS NULL OR OLD.registered_at<=cutoff OR NEW.registered_at<=cutoff) THEN
   RAISE EXCEPTION 'patient_registration_paid_period_locked' USING ERRCODE='23514';
  END IF;
 END LOOP;
 RETURN NULL;
END;
$body$;
REVOKE ALL ON FUNCTION public.guard_patient_registration_financial_time() FROM PUBLIC;
CREATE TRIGGER patient_registration_financial_time AFTER UPDATE ON public.patients
 FOR EACH ROW EXECUTE FUNCTION public.guard_patient_registration_financial_time();
COMMIT;
