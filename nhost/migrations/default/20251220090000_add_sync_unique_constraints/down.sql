-- Drops unique constraints required by Hasura on_conflict for sync tables.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'patients_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.patients
      DROP CONSTRAINT patients_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'returns_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.returns
      DROP CONSTRAINT returns_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'consumptions_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.consumptions
      DROP CONSTRAINT consumptions_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drugs_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.drugs
      DROP CONSTRAINT drugs_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'prescriptions_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.prescriptions
      DROP CONSTRAINT prescriptions_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'prescription_items_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.prescription_items
      DROP CONSTRAINT prescription_items_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'complaints_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.complaints
      DROP CONSTRAINT complaints_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'appointments_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.appointments
      DROP CONSTRAINT appointments_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'doctors_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.doctors
      DROP CONSTRAINT doctors_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'consumption_types_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.consumption_types
      DROP CONSTRAINT consumption_types_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'medical_services_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.medical_services
      DROP CONSTRAINT medical_services_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'service_doctor_share_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.service_doctor_share
      DROP CONSTRAINT service_doctor_share_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employees_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.employees
      DROP CONSTRAINT employees_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employees_loans_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.employees_loans
      DROP CONSTRAINT employees_loans_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employees_salaries_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.employees_salaries
      DROP CONSTRAINT employees_salaries_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employees_discounts_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.employees_discounts
      DROP CONSTRAINT employees_discounts_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'item_types_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.item_types
      DROP CONSTRAINT item_types_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'items_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.items
      DROP CONSTRAINT items_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'purchases_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.purchases
      DROP CONSTRAINT purchases_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'alert_settings_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.alert_settings
      DROP CONSTRAINT alert_settings_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'financial_logs_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.financial_logs
      DROP CONSTRAINT financial_logs_account_id_device_id_local_id_key;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'patient_services_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.patient_services
      DROP CONSTRAINT patient_services_account_id_device_id_local_id_key;
  END IF;
END $$;
