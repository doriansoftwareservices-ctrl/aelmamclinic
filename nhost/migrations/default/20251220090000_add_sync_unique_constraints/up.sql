-- Adds unique constraints required by Hasura on_conflict for sync tables.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'patients_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.patients
      ADD CONSTRAINT patients_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'returns_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.returns
      ADD CONSTRAINT returns_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'consumptions_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.consumptions
      ADD CONSTRAINT consumptions_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drugs_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.drugs
      ADD CONSTRAINT drugs_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'prescriptions_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.prescriptions
      ADD CONSTRAINT prescriptions_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'prescription_items_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.prescription_items
      ADD CONSTRAINT prescription_items_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'complaints_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.complaints
      ADD CONSTRAINT complaints_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'appointments_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.appointments
      ADD CONSTRAINT appointments_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'doctors_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.doctors
      ADD CONSTRAINT doctors_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'consumption_types_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.consumption_types
      ADD CONSTRAINT consumption_types_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'medical_services_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.medical_services
      ADD CONSTRAINT medical_services_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'service_doctor_share_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.service_doctor_share
      ADD CONSTRAINT service_doctor_share_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employees_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.employees
      ADD CONSTRAINT employees_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employees_loans_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.employees_loans
      ADD CONSTRAINT employees_loans_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employees_salaries_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.employees_salaries
      ADD CONSTRAINT employees_salaries_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'employees_discounts_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.employees_discounts
      ADD CONSTRAINT employees_discounts_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'item_types_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.item_types
      ADD CONSTRAINT item_types_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'items_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.items
      ADD CONSTRAINT items_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'purchases_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.purchases
      ADD CONSTRAINT purchases_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'alert_settings_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.alert_settings
      ADD CONSTRAINT alert_settings_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'financial_logs_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.financial_logs
      ADD CONSTRAINT financial_logs_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'patient_services_account_id_device_id_local_id_key'
  ) THEN
    ALTER TABLE public.patient_services
      ADD CONSTRAINT patient_services_account_id_device_id_local_id_key
      UNIQUE (account_id, device_id, local_id);
  END IF;
END $$;
