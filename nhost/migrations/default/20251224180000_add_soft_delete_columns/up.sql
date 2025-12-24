-- Add is_deleted/deleted_at columns for sync tables to align with local soft delete.
DO $$
DECLARE
  tbl text;
BEGIN
  FOR tbl IN SELECT unnest(ARRAY[
    'patients',
    'returns',
    'consumptions',
    'drugs',
    'prescriptions',
    'prescription_items',
    'complaints',
    'appointments',
    'doctors',
    'consumption_types',
    'medical_services',
    'service_doctor_share',
    'employees',
    'employees_loans',
    'employees_salaries',
    'employees_discounts',
    'items',
    'item_types',
    'purchases',
    'alert_settings',
    'financial_logs',
    'patient_services'
  ]) LOOP
    EXECUTE format(
      'ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false',
      tbl
    );
    EXECUTE format(
      'ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS deleted_at timestamptz',
      tbl
    );
    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I ON public.%I (is_deleted)',
      'idx_' || tbl || '_is_deleted',
      tbl
    );
  END LOOP;
END $$;
