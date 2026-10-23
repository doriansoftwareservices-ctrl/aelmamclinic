BEGIN;
SET LOCAL lock_timeout = '5s';

-- The timestamp/id pull cursor must follow visibility, not transaction start.
-- Every writer of a clinic's domain rows obtains the same transactional clock
-- lock. It remains held until COMMIT/ROLLBACK; a later committing writer cannot
-- allocate a timestamp behind an already visible cursor. Existing business
-- dates, versions, receipts and all historical updated_at values are unchanged.
CREATE TABLE IF NOT EXISTS public.clinic_pull_clocks (
  account_id uuid PRIMARY KEY,
  last_at timestamptz NOT NULL
);
ALTER TABLE public.clinic_pull_clocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.clinic_pull_clocks FROM PUBLIC;

-- Block writers while seeding and installing the complete set of triggers.
-- A partial installation cannot commit. Readers remain available.
LOCK TABLE public.alert_settings, public.appointments, public.complaints, public.consumption_types, public.consumptions, public.doctors, public.drugs, public.employees, public.employees_discounts, public.employees_loans, public.employees_salaries, public.financial_logs, public.item_types, public.items, public.medical_services, public.patient_services, public.patients, public.prescription_items, public.prescriptions, public.purchases, public.returns, public.service_doctor_share IN SHARE ROW EXCLUSIVE MODE;

INSERT INTO public.clinic_pull_clocks(account_id,last_at)
SELECT account_id, max(updated_at)
FROM (
  SELECT account_id,updated_at FROM public.item_types
UNION ALL
  SELECT account_id,updated_at FROM public.items
UNION ALL
  SELECT account_id,updated_at FROM public.drugs
UNION ALL
  SELECT account_id,updated_at FROM public.medical_services
UNION ALL
  SELECT account_id,updated_at FROM public.consumption_types
UNION ALL
  SELECT account_id,updated_at FROM public.employees
UNION ALL
  SELECT account_id,updated_at FROM public.doctors
UNION ALL
  SELECT account_id,updated_at FROM public.service_doctor_share
UNION ALL
  SELECT account_id,updated_at FROM public.patients
UNION ALL
  SELECT account_id,updated_at FROM public.patient_services
UNION ALL
  SELECT account_id,updated_at FROM public.returns
UNION ALL
  SELECT account_id,updated_at FROM public.appointments
UNION ALL
  SELECT account_id,updated_at FROM public.prescriptions
UNION ALL
  SELECT account_id,updated_at FROM public.prescription_items
UNION ALL
  SELECT account_id,updated_at FROM public.purchases
UNION ALL
  SELECT account_id,updated_at FROM public.consumptions
UNION ALL
  SELECT account_id,updated_at FROM public.alert_settings
UNION ALL
  SELECT account_id,updated_at FROM public.employees_loans
UNION ALL
  SELECT account_id,updated_at FROM public.employees_salaries
UNION ALL
  SELECT account_id,updated_at FROM public.employees_discounts
UNION ALL
  SELECT account_id,updated_at FROM public.complaints
UNION ALL
  SELECT account_id,updated_at FROM public.financial_logs
) history
WHERE account_id IS NOT NULL AND updated_at IS NOT NULL
GROUP BY account_id
ON CONFLICT(account_id) DO UPDATE
SET last_at = GREATEST(public.clinic_pull_clocks.last_at, EXCLUDED.last_at);

CREATE OR REPLACE FUNCTION public.tg_clinic_pull_clock()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,public
AS $function$
BEGIN
  IF NEW.account_id IS NULL THEN
    RAISE EXCEPTION 'sync_account_required' USING ERRCODE='23502';
  END IF;
  INSERT INTO public.clinic_pull_clocks(account_id,last_at)
  VALUES (NEW.account_id, clock_timestamp())
  ON CONFLICT(account_id) DO UPDATE
  SET last_at = GREATEST(clock_timestamp(),
    public.clinic_pull_clocks.last_at + interval '1 microsecond')
  RETURNING last_at INTO NEW.updated_at;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.tg_clinic_pull_clock() FROM PUBLIC;

DO $install$
DECLARE domain_table text;
BEGIN
  FOREACH domain_table IN ARRAY ARRAY['item_types','items','drugs','medical_services','consumption_types','employees','doctors','service_doctor_share','patients','patient_services','returns','appointments','prescriptions','prescription_items','purchases','consumptions','alert_settings','employees_loans','employees_salaries','employees_discounts','complaints','financial_logs'] LOOP
    -- PostgreSQL executes triggers of the same kind in name order. Refuse an
    -- installation where another existing BEFORE row trigger would run later.
    IF EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = ('public.'||domain_table)::regclass
        AND NOT tgisinternal AND tgenabled <> 'D'
        AND (tgtype::integer & 3) = 3
        AND (tgtype::integer & 20) <> 0
        AND tgname > 'zzzz_clinic_pull_clock'
    ) THEN
      RAISE EXCEPTION 'pull_clock_trigger_order_invalid: %',domain_table;
    END IF;
    EXECUTE format('DROP TRIGGER IF EXISTS zzzz_clinic_pull_clock ON public.%I',domain_table);
    EXECUTE format('CREATE TRIGGER zzzz_clinic_pull_clock BEFORE INSERT OR UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.tg_clinic_pull_clock()',domain_table);
  END LOOP;
END;
$install$;
COMMIT;
