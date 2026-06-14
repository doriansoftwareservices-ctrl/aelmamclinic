DROP INDEX IF EXISTS public.idx_appointments_client_mutation_id;
DROP INDEX IF EXISTS public.idx_appointments_account_deleted_updated;
DROP INDEX IF EXISTS public.idx_patients_client_mutation_id;
DROP INDEX IF EXISTS public.idx_patients_account_deleted_updated;
DROP INDEX IF EXISTS public.idx_item_types_client_mutation_id;
DROP INDEX IF EXISTS public.idx_items_client_mutation_id;
DROP INDEX IF EXISTS public.idx_drugs_client_mutation_id;
DROP INDEX IF EXISTS public.idx_medical_services_client_mutation_id;
DROP INDEX IF EXISTS public.idx_consumption_types_client_mutation_id;
DROP INDEX IF EXISTS public.idx_service_doctor_share_client_mutation_id;
DROP INDEX IF EXISTS public.idx_employees_client_mutation_id;
DROP INDEX IF EXISTS public.idx_doctors_client_mutation_id;
DROP INDEX IF EXISTS public.idx_patient_services_client_mutation_id;
DROP INDEX IF EXISTS public.idx_returns_client_mutation_id;
DROP INDEX IF EXISTS public.idx_prescriptions_client_mutation_id;
DROP INDEX IF EXISTS public.idx_prescription_items_client_mutation_id;
DROP INDEX IF EXISTS public.idx_consumptions_client_mutation_id;
DROP INDEX IF EXISTS public.idx_purchases_client_mutation_id;
DROP INDEX IF EXISTS public.idx_alert_settings_client_mutation_id;
DROP INDEX IF EXISTS public.idx_employees_loans_client_mutation_id;
DROP INDEX IF EXISTS public.idx_employees_salaries_client_mutation_id;
DROP INDEX IF EXISTS public.idx_employees_discounts_client_mutation_id;
DROP INDEX IF EXISTS public.idx_complaints_client_mutation_id;
DROP INDEX IF EXISTS public.idx_financial_logs_client_mutation_id;
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
    EXECUTE format('DROP INDEX IF EXISTS public.%I', 'idx_' || sync_table || '_account_updated_cursor');
    EXECUTE format('DROP INDEX IF EXISTS public.%I', 'idx_' || sync_table || '_account_deleted_updated');
  END LOOP;
END $$;
DROP INDEX IF EXISTS public.idx_sync_events_account_domain_created;
DROP INDEX IF EXISTS public.idx_sync_events_account_created;
DROP INDEX IF EXISTS public.idx_client_mutations_account_created;

DROP TABLE IF EXISTS public.sync_events;
DROP TABLE IF EXISTS public.client_mutations;
