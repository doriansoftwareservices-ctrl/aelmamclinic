BEGIN;

-- Transitional money contract: legacy numeric columns remain readable while
-- integer minor-unit columns are backfilled and kept in sync both ways.
CREATE TABLE IF NOT EXISTS public.money_reconciliation_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  entity_table text NOT NULL,
  entity_id text NOT NULL,
  column_name text NOT NULL,
  issue_code text NOT NULL,
  legacy_value text,
  proposed_minor bigint,
  rounding_delta numeric,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'open',
  detected_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolved_by_user_id uuid,
  CONSTRAINT money_reconciliation_status_check
    CHECK (status IN ('open', 'reviewed', 'resolved', 'ignored'))
);

CREATE UNIQUE INDEX IF NOT EXISTS money_reconciliation_open_uix
  ON public.money_reconciliation_issues (
    COALESCE(account_id, '00000000-0000-0000-0000-000000000000'::uuid),
    entity_table,
    entity_id,
    column_name,
    issue_code
  )
  WHERE status = 'open';

ALTER TABLE public.patients
  ADD COLUMN IF NOT EXISTS paid_amount_minor bigint,
  ADD COLUMN IF NOT EXISTS remaining_minor bigint,
  ADD COLUMN IF NOT EXISTS service_cost_minor bigint,
  ADD COLUMN IF NOT EXISTS doctor_share_minor bigint,
  ADD COLUMN IF NOT EXISTS doctor_input_minor bigint,
  ADD COLUMN IF NOT EXISTS tower_share_minor bigint,
  ADD COLUMN IF NOT EXISTS department_share_minor bigint;
ALTER TABLE public.returns
  ADD COLUMN IF NOT EXISTS remaining_minor bigint;
ALTER TABLE public.consumptions
  ADD COLUMN IF NOT EXISTS amount_minor bigint;
ALTER TABLE public.medical_services
  ADD COLUMN IF NOT EXISTS cost_minor bigint;
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS basic_salary_minor bigint,
  ADD COLUMN IF NOT EXISTS final_salary_minor bigint;
ALTER TABLE public.employees_loans
  ADD COLUMN IF NOT EXISTS final_salary_minor bigint,
  ADD COLUMN IF NOT EXISTS ratio_sum_minor bigint,
  ADD COLUMN IF NOT EXISTS loan_amount_minor bigint,
  ADD COLUMN IF NOT EXISTS leftover_minor bigint;
ALTER TABLE public.employees_salaries
  ADD COLUMN IF NOT EXISTS final_salary_minor bigint,
  ADD COLUMN IF NOT EXISTS ratio_sum_minor bigint,
  ADD COLUMN IF NOT EXISTS total_loans_minor bigint,
  ADD COLUMN IF NOT EXISTS total_discounts_minor bigint,
  ADD COLUMN IF NOT EXISTS net_pay_minor bigint;
ALTER TABLE public.employees_discounts
  ADD COLUMN IF NOT EXISTS amount_minor bigint;
ALTER TABLE public.items
  ADD COLUMN IF NOT EXISTS price_minor bigint;
ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS amount_minor bigint;
ALTER TABLE public.financial_logs
  ADD COLUMN IF NOT EXISTS amount_minor bigint;
ALTER TABLE public.patient_services
  ADD COLUMN IF NOT EXISTS service_cost_minor bigint;
ALTER TABLE public.subscription_plans
  ADD COLUMN IF NOT EXISTS price_usd_minor bigint;
ALTER TABLE public.subscription_requests
  ADD COLUMN IF NOT EXISTS amount_minor bigint;
ALTER TABLE public.subscription_payments
  ADD COLUMN IF NOT EXISTS amount_minor bigint;
ALTER TABLE public.employee_seat_requests
  ADD COLUMN IF NOT EXISTS price_usd_minor bigint;
ALTER TABLE public.employee_seat_pricing
  ADD COLUMN IF NOT EXISTS price_usd_minor bigint;
ALTER TABLE public.employee_seat_payments
  ADD COLUMN IF NOT EXISTS amount_minor bigint;

CREATE OR REPLACE FUNCTION public.money_to_minor_or_null(p_value numeric)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $function$
BEGIN
  IF lower(p_value::text) IN ('nan', 'infinity', '-infinity')
     OR abs(p_value) > 92233720368547758.07 THEN
    RETURN NULL;
  END IF;
  RETURN round(p_value * 100)::bigint;
END;
$function$;

REVOKE ALL ON FUNCTION public.money_to_minor_or_null(numeric) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.money_minor_dual_write()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  legacy_key text := TG_ARGV[0];
  minor_key text := TG_ARGV[1];
  legacy_raw text := to_jsonb(NEW) ->> legacy_key;
  minor_raw text := to_jsonb(NEW) ->> minor_key;
  legacy_changed boolean;
  minor_changed boolean;
  legacy_value numeric;
  minor_value bigint;
  expected_minor bigint;
BEGIN
  IF TG_OP = 'INSERT' THEN
    legacy_changed := legacy_raw IS NOT NULL;
    minor_changed := minor_raw IS NOT NULL;
  ELSE
    legacy_changed := (to_jsonb(NEW) -> legacy_key)
      IS DISTINCT FROM (to_jsonb(OLD) -> legacy_key);
    minor_changed := (to_jsonb(NEW) -> minor_key)
      IS DISTINCT FROM (to_jsonb(OLD) -> minor_key);
  END IF;

  IF legacy_changed AND legacy_raw IS NULL THEN
    IF minor_changed AND minor_raw IS NOT NULL THEN
      RAISE EXCEPTION 'money_dual_write_conflicting_nulls'
        USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_populate_record(
      NEW,
      jsonb_build_object(minor_key, NULL)
    );
  END IF;

  IF minor_changed AND NOT legacy_changed THEN
    IF minor_raw IS NULL THEN
      RETURN jsonb_populate_record(
        NEW,
        jsonb_build_object(legacy_key, NULL)
      );
    END IF;
    minor_value := minor_raw::bigint;
    RETURN jsonb_populate_record(
      NEW,
      jsonb_build_object(legacy_key, minor_value::numeric / 100)
    );
  END IF;

  IF legacy_raw IS NULL THEN
    RETURN NEW;
  END IF;

  legacy_value := legacy_raw::numeric;
  expected_minor := public.money_to_minor_or_null(legacy_value);
  IF expected_minor IS NULL THEN
    RAISE EXCEPTION 'money_value_out_of_minor_range'
      USING ERRCODE = '22003';
  END IF;

  IF legacy_changed AND minor_changed AND minor_raw IS NOT NULL
     AND minor_raw::bigint <> expected_minor THEN
    RAISE EXCEPTION 'money_minor_mismatch'
      USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_populate_record(
    NEW,
    jsonb_build_object(minor_key, expected_minor)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.money_minor_dual_write() FROM PUBLIC;

DO $do$
DECLARE
  spec jsonb;
  v_table_name text;
  v_legacy_name text;
  v_minor_name text;
  v_entity_key text;
  v_account_expression text;
  v_trigger_name text;
BEGIN
  FOR spec IN
    SELECT value
      FROM jsonb_array_elements(
        '[
          {"table":"patients","legacy":"paid_amount","minor":"paid_amount_minor"},
          {"table":"patients","legacy":"remaining","minor":"remaining_minor"},
          {"table":"patients","legacy":"service_cost","minor":"service_cost_minor"},
          {"table":"patients","legacy":"doctor_share","minor":"doctor_share_minor"},
          {"table":"patients","legacy":"doctor_input","minor":"doctor_input_minor"},
          {"table":"patients","legacy":"tower_share","minor":"tower_share_minor"},
          {"table":"patients","legacy":"department_share","minor":"department_share_minor"},
          {"table":"returns","legacy":"remaining","minor":"remaining_minor"},
          {"table":"consumptions","legacy":"amount","minor":"amount_minor"},
          {"table":"medical_services","legacy":"cost","minor":"cost_minor"},
          {"table":"employees","legacy":"basic_salary","minor":"basic_salary_minor"},
          {"table":"employees","legacy":"final_salary","minor":"final_salary_minor"},
          {"table":"employees_loans","legacy":"final_salary","minor":"final_salary_minor"},
          {"table":"employees_loans","legacy":"ratio_sum","minor":"ratio_sum_minor"},
          {"table":"employees_loans","legacy":"loan_amount","minor":"loan_amount_minor"},
          {"table":"employees_loans","legacy":"leftover","minor":"leftover_minor"},
          {"table":"employees_salaries","legacy":"final_salary","minor":"final_salary_minor"},
          {"table":"employees_salaries","legacy":"ratio_sum","minor":"ratio_sum_minor"},
          {"table":"employees_salaries","legacy":"total_loans","minor":"total_loans_minor"},
          {"table":"employees_salaries","legacy":"total_discounts","minor":"total_discounts_minor"},
          {"table":"employees_salaries","legacy":"net_pay","minor":"net_pay_minor"},
          {"table":"employees_discounts","legacy":"amount","minor":"amount_minor"},
          {"table":"items","legacy":"price","minor":"price_minor"},
          {"table":"purchases","legacy":"total","minor":"amount_minor"},
          {"table":"financial_logs","legacy":"amount","minor":"amount_minor"},
          {"table":"patient_services","legacy":"service_cost","minor":"service_cost_minor"},
          {"table":"subscription_plans","legacy":"price_usd","minor":"price_usd_minor","key":"code","global":true},
          {"table":"subscription_requests","legacy":"amount","minor":"amount_minor"},
          {"table":"subscription_payments","legacy":"amount","minor":"amount_minor"},
          {"table":"employee_seat_requests","legacy":"price_usd","minor":"price_usd_minor"},
          {"table":"employee_seat_pricing","legacy":"price_usd","minor":"price_usd_minor","key":"seat_kind","global":true},
          {"table":"employee_seat_payments","legacy":"amount","minor":"amount_minor"}
        ]'::jsonb
      )
  LOOP
    v_table_name := spec ->> 'table';
    v_legacy_name := spec ->> 'legacy';
    v_minor_name := spec ->> 'minor';
    v_entity_key := COALESCE(spec ->> 'key', 'id');
    v_account_expression := CASE
      WHEN COALESCE((spec ->> 'global')::boolean, false)
        THEN 'NULL::uuid'
      ELSE 'account_id'
    END;

    IF to_regclass('public.' || v_table_name) IS NULL OR NOT EXISTS (
      SELECT 1
        FROM information_schema.columns AS c
       WHERE c.table_schema = 'public'
         AND c.table_name = v_table_name
         AND c.column_name = v_legacy_name
    ) THEN
      CONTINUE;
    END IF;

    EXECUTE format($sql$
      INSERT INTO public.money_reconciliation_issues (
        account_id, entity_table, entity_id, column_name, issue_code,
        legacy_value, details
      )
      SELECT %s, %L, %I::text, %L, 'minor_unit_out_of_range',
             %I::text, jsonb_build_object('rounding_policy', 'half_away_from_zero')
       FROM public.%I
       WHERE %I IS NOT NULL
         AND public.money_to_minor_or_null(%I::numeric) IS NULL
      ON CONFLICT DO NOTHING
    $sql$, v_account_expression, v_table_name, v_entity_key, v_legacy_name,
      v_legacy_name, v_table_name, v_legacy_name, v_legacy_name);

    EXECUTE format($sql$
      INSERT INTO public.money_reconciliation_issues (
        account_id, entity_table, entity_id, column_name, issue_code,
        legacy_value, proposed_minor, rounding_delta, details
      )
      SELECT %s, %L, %I::text, %L, 'fractional_minor_unit',
             %I::text, public.money_to_minor_or_null(%I::numeric),
             (%I::numeric * 100)
               - public.money_to_minor_or_null(%I::numeric),
             jsonb_build_object('rounding_policy', 'half_away_from_zero')
        FROM public.%I
       WHERE %I IS NOT NULL
         AND public.money_to_minor_or_null(%I::numeric) IS NOT NULL
         AND abs(
           (%I::numeric * 100)
             - public.money_to_minor_or_null(%I::numeric)
         ) > 0.000001
      ON CONFLICT DO NOTHING
    $sql$, v_account_expression, v_table_name, v_entity_key, v_legacy_name,
      v_legacy_name, v_legacy_name, v_legacy_name, v_legacy_name,
      v_table_name, v_legacy_name, v_legacy_name, v_legacy_name,
      v_legacy_name);

    EXECUTE format($sql$
      UPDATE public.%I
         SET %I = public.money_to_minor_or_null(%I::numeric)
       WHERE %I IS NULL
         AND %I IS NOT NULL
         AND public.money_to_minor_or_null(%I::numeric) IS NOT NULL
    $sql$, v_table_name, v_minor_name, v_legacy_name, v_minor_name,
      v_legacy_name, v_legacy_name);

    v_trigger_name := 'trg_money_' || substr(
      md5(v_table_name || ':' || v_legacy_name || ':' || v_minor_name),
      1,
      24
    );
    EXECUTE format(
      'DROP TRIGGER IF EXISTS %I ON public.%I',
      v_trigger_name,
      v_table_name
    );
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE INSERT OR UPDATE OF %I, %I ON public.%I '
      || 'FOR EACH ROW EXECUTE FUNCTION public.money_minor_dual_write(%L, %L)',
      v_trigger_name,
      v_legacy_name,
      v_minor_name,
      v_table_name,
      v_legacy_name,
      v_minor_name
    );
  END LOOP;
END
$do$;

-- Every tenant-owned foreign key below proves that both sides belong to the
-- same account. NOT VALID preserves legacy evidence while enforcing new rows.
ALTER TABLE public.patients
  DROP CONSTRAINT IF EXISTS patients_doctor_same_account_fk,
  DROP CONSTRAINT IF EXISTS patients_service_same_account_fk;
ALTER TABLE public.patients
  ADD CONSTRAINT patients_doctor_same_account_fk
    FOREIGN KEY (account_id, doctor_id)
    REFERENCES public.doctors(account_id, id) NOT VALID,
  ADD CONSTRAINT patients_service_same_account_fk
    FOREIGN KEY (account_id, service_id)
    REFERENCES public.medical_services(account_id, id) NOT VALID;

ALTER TABLE public.employees_loans
  DROP CONSTRAINT IF EXISTS employees_loans_employee_same_account_fk;
ALTER TABLE public.employees_loans
  ADD CONSTRAINT employees_loans_employee_same_account_fk
    FOREIGN KEY (account_id, employee_id)
    REFERENCES public.employees(account_id, id) NOT VALID;

ALTER TABLE public.employees_salaries
  DROP CONSTRAINT IF EXISTS employees_salaries_employee_same_account_fk;
ALTER TABLE public.employees_salaries
  ADD CONSTRAINT employees_salaries_employee_same_account_fk
    FOREIGN KEY (account_id, employee_id)
    REFERENCES public.employees(account_id, id) NOT VALID;

ALTER TABLE public.employees_discounts
  DROP CONSTRAINT IF EXISTS employees_discounts_employee_same_account_fk;
ALTER TABLE public.employees_discounts
  ADD CONSTRAINT employees_discounts_employee_same_account_fk
    FOREIGN KEY (account_id, employee_id)
    REFERENCES public.employees(account_id, id) NOT VALID;

ALTER TABLE public.financial_logs
  DROP CONSTRAINT IF EXISTS financial_logs_patient_same_account_fk;
ALTER TABLE public.financial_logs
  ADD CONSTRAINT financial_logs_patient_same_account_fk
    FOREIGN KEY (account_id, patient_id)
    REFERENCES public.patients(account_id, id) NOT VALID;

COMMIT;
