-- Remove soft delete columns added in up.sql.
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
    EXECUTE format('DROP INDEX IF EXISTS %I', 'idx_' || tbl || '_is_deleted');
    EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS deleted_at', tbl);
    EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS is_deleted', tbl);
  END LOOP;
END $$;
