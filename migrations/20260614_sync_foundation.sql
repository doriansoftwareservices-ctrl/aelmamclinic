CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.client_mutations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  client_mutation_id text NOT NULL UNIQUE,
  operation_type text NOT NULL,
  actor_user_id uuid,
  payload_hash text,
  result_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_client_mutations_account_created
  ON public.client_mutations(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.sync_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  domain text NOT NULL,
  entity_table text NOT NULL,
  entity_id uuid,
  operation_type text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  actor_user_id uuid
);

CREATE INDEX IF NOT EXISTS idx_sync_events_account_created
  ON public.sync_events(account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_sync_events_account_domain_created
  ON public.sync_events(account_id, domain, created_at DESC);

ALTER TABLE public.patients
  ADD COLUMN IF NOT EXISTS client_mutation_id text,
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS deletion_client_mutation_id text,
  ADD COLUMN IF NOT EXISTS server_version integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS updated_by_user_id uuid;

CREATE INDEX IF NOT EXISTS idx_patients_account_deleted_updated
  ON public.patients(account_id, is_deleted, updated_at, id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_patients_client_mutation_id
  ON public.patients(client_mutation_id)
  WHERE client_mutation_id IS NOT NULL;

ALTER TABLE public.appointments
  ADD COLUMN IF NOT EXISTS client_mutation_id text,
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by_user_id uuid,
  ADD COLUMN IF NOT EXISTS deletion_client_mutation_id text,
  ADD COLUMN IF NOT EXISTS server_version integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS updated_by_user_id uuid;

CREATE INDEX IF NOT EXISTS idx_appointments_account_deleted_updated
  ON public.appointments(account_id, is_deleted, updated_at, id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_appointments_client_mutation_id
  ON public.appointments(client_mutation_id)
  WHERE client_mutation_id IS NOT NULL;

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
    EXECUTE format(
      'ALTER TABLE public.%I
        ADD COLUMN IF NOT EXISTS client_mutation_id text,
        ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
        ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
        ADD COLUMN IF NOT EXISTS deleted_by_user_id uuid,
        ADD COLUMN IF NOT EXISTS deletion_client_mutation_id text,
        ADD COLUMN IF NOT EXISTS server_version integer NOT NULL DEFAULT 0,
        ADD COLUMN IF NOT EXISTS updated_by_user_id uuid',
      sync_table
    );

    EXECUTE format(
      'CREATE UNIQUE INDEX IF NOT EXISTS %I
        ON public.%I(client_mutation_id)
        WHERE client_mutation_id IS NOT NULL',
      'idx_' || sync_table || '_client_mutation_id',
      sync_table
    );

    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I
        ON public.%I(account_id, updated_at, id)',
      'idx_' || sync_table || '_account_updated_cursor',
      sync_table
    );

    EXECUTE format(
      'CREATE INDEX IF NOT EXISTS %I
        ON public.%I(account_id, is_deleted, updated_at, id)',
      'idx_' || sync_table || '_account_deleted_updated',
      sync_table
    );
  END LOOP;
END $$;
