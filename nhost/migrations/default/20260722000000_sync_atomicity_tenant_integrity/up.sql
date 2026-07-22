BEGIN;

ALTER TABLE public.client_mutations
  DROP CONSTRAINT IF EXISTS client_mutations_client_mutation_id_key;
ALTER TABLE public.client_mutations
  ADD CONSTRAINT client_mutations_account_id_client_mutation_id_key
  UNIQUE (account_id, client_mutation_id);
ALTER TABLE public.client_mutations
  ADD COLUMN IF NOT EXISTS completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS correlation_id uuid;

ALTER TABLE public.sync_events
  ADD COLUMN IF NOT EXISTS client_mutation_id text,
  ADD COLUMN IF NOT EXISTS correlation_id uuid;
CREATE UNIQUE INDEX IF NOT EXISTS sync_events_account_client_mutation_uix
  ON public.sync_events(account_id, client_mutation_id)
  WHERE client_mutation_id IS NOT NULL;

DO $do$
DECLARE
  sync_table text;
BEGIN
  FOREACH sync_table IN ARRAY ARRAY[
    'item_types', 'items', 'drugs', 'medical_services', 'consumption_types',
    'service_doctor_share', 'employees', 'doctors', 'patients',
    'patient_services', 'returns', 'appointments', 'prescriptions',
    'prescription_items', 'consumptions', 'purchases', 'alert_settings',
    'employees_loans', 'employees_salaries', 'employees_discounts',
    'complaints', 'financial_logs'
  ] LOOP
    IF to_regclass('public.' || sync_table) IS NULL THEN CONTINUE; END IF;
    EXECUTE format('DROP INDEX IF EXISTS public.%I',
                   'idx_' || sync_table || '_client_mutation_id');
    EXECUTE format(
      'CREATE UNIQUE INDEX IF NOT EXISTS %I
         ON public.%I(account_id, client_mutation_id)
       WHERE client_mutation_id IS NOT NULL',
      'idx_' || sync_table || '_account_client_mutation_id', sync_table
    );
    EXECUTE format(
      'CREATE UNIQUE INDEX IF NOT EXISTS %I ON public.%I(account_id, id)',
      'uq_' || sync_table || '_account_id', sync_table
    );
  END LOOP;
END
$do$;

ALTER TABLE public.client_mutations
  ADD CONSTRAINT client_mutations_account_fk
  FOREIGN KEY (account_id) REFERENCES public.accounts(id)
  ON DELETE CASCADE NOT VALID;
ALTER TABLE public.sync_events
  ADD CONSTRAINT sync_events_account_fk
  FOREIGN KEY (account_id) REFERENCES public.accounts(id)
  ON DELETE CASCADE NOT VALID;

ALTER TABLE public.items
  ADD CONSTRAINT items_type_same_account_fk
  FOREIGN KEY (account_id, type_id)
  REFERENCES public.item_types(account_id, id) NOT VALID;
ALTER TABLE public.doctors
  ADD CONSTRAINT doctors_employee_same_account_fk
  FOREIGN KEY (account_id, employee_id)
  REFERENCES public.employees(account_id, id) NOT VALID;
ALTER TABLE public.service_doctor_share
  ADD CONSTRAINT service_share_service_same_account_fk
  FOREIGN KEY (account_id, service_id)
  REFERENCES public.medical_services(account_id, id) NOT VALID,
  ADD CONSTRAINT service_share_doctor_same_account_fk
  FOREIGN KEY (account_id, doctor_id)
  REFERENCES public.doctors(account_id, id) NOT VALID;
ALTER TABLE public.patient_services
  ADD CONSTRAINT patient_services_patient_same_account_fk
  FOREIGN KEY (account_id, patient_id)
  REFERENCES public.patients(account_id, id) NOT VALID,
  ADD CONSTRAINT patient_services_service_same_account_fk
  FOREIGN KEY (account_id, service_id)
  REFERENCES public.medical_services(account_id, id) NOT VALID;
ALTER TABLE public.appointments
  ADD CONSTRAINT appointments_patient_same_account_fk
  FOREIGN KEY (account_id, patient_id)
  REFERENCES public.patients(account_id, id) NOT VALID,
  ADD CONSTRAINT appointments_doctor_same_account_fk
  FOREIGN KEY (account_id, doctor_id)
  REFERENCES public.doctors(account_id, id) NOT VALID;
ALTER TABLE public.prescriptions
  ADD CONSTRAINT prescriptions_patient_same_account_fk
  FOREIGN KEY (account_id, patient_id)
  REFERENCES public.patients(account_id, id) NOT VALID,
  ADD CONSTRAINT prescriptions_doctor_same_account_fk
  FOREIGN KEY (account_id, doctor_id)
  REFERENCES public.doctors(account_id, id) NOT VALID;
ALTER TABLE public.prescription_items
  ADD CONSTRAINT prescription_items_parent_same_account_fk
  FOREIGN KEY (account_id, prescription_id)
  REFERENCES public.prescriptions(account_id, id) NOT VALID,
  ADD CONSTRAINT prescription_items_drug_same_account_fk
  FOREIGN KEY (account_id, drug_id)
  REFERENCES public.drugs(account_id, id) NOT VALID;
ALTER TABLE public.purchases
  ADD CONSTRAINT purchases_item_same_account_fk
  FOREIGN KEY (account_id, item_id)
  REFERENCES public.items(account_id, id) NOT VALID;
ALTER TABLE public.alert_settings
  ADD CONSTRAINT alert_settings_item_same_account_fk
  FOREIGN KEY (account_id, item_id)
  REFERENCES public.items(account_id, id) NOT VALID,
  ADD CONSTRAINT alert_settings_item_uuid_same_account_fk
  FOREIGN KEY (account_id, item_uuid)
  REFERENCES public.items(account_id, id) NOT VALID;

COMMIT;
