-- Safe rollback: remove only the trigger guardrails, not the sync columns/data.
DO $$
DECLARE
  sync_table text;
BEGIN
  FOREACH sync_table IN ARRAY ARRAY[
    'item_types',
    'items',
    'drugs',
    'medical_services',
    'consumption_types',
    'service_doctor_share',
    'employees',
    'doctors',
    'patients',
    'patient_services',
    'returns',
    'appointments',
    'prescriptions',
    'prescription_items',
    'consumptions',
    'purchases',
    'alert_settings',
    'employees_loans',
    'employees_salaries',
    'employees_discounts',
    'complaints',
    'financial_logs'
  ]
  LOOP
    IF to_regclass('public.' || quote_ident(sync_table)) IS NULL THEN
      CONTINUE;
    END IF;

    EXECUTE format(
      'DROP TRIGGER IF EXISTS %I ON public.%I',
      'tg_' || sync_table || '_clinic_sync_touch',
      sync_table
    );
  END LOOP;
END $$;

DROP FUNCTION IF EXISTS public.tg_clinic_sync_touch_row();
