-- Sync guardrails for ElmamClinic.
-- الهدف:
-- 1) ضمان وجود أعمدة المزامنة والفهارس حتى لو وصلت قاعدة الإنتاج من مسار Migration قديم.
-- 2) جعل server_version يتغير فعليًا مع كل INSERT/UPDATE حتى تعتمد المزامنة على نسخة خادم موثوقة.
-- 3) تحديث updated_at من الخادم لمنع الاعتماد على وقت جهاز العميل.

CREATE OR REPLACE FUNCTION public.tg_clinic_sync_touch_row()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();

  IF TG_OP = 'INSERT' THEN
    NEW.server_version := GREATEST(COALESCE(NEW.server_version, 0), 1);
  ELSE
    NEW.server_version := COALESCE(OLD.server_version, 0) + 1;
  END IF;

  RETURN NEW;
END;
$$;

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
      RAISE NOTICE 'Skipping missing sync table: %', sync_table;
      CONTINUE;
    END IF;

    EXECUTE format(
      'ALTER TABLE public.%I
        ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
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

    EXECUTE format(
      'DROP TRIGGER IF EXISTS %I ON public.%I',
      'tg_' || sync_table || '_clinic_sync_touch',
      sync_table
    );

    EXECUTE format(
      'CREATE TRIGGER %I
        BEFORE INSERT OR UPDATE ON public.%I
        FOR EACH ROW
        EXECUTE FUNCTION public.tg_clinic_sync_touch_row()',
      'tg_' || sync_table || '_clinic_sync_touch',
      sync_table
    );
  END LOOP;
END $$;
