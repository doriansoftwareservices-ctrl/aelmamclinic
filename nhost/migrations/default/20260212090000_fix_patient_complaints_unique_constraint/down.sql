BEGIN;

DO $$
DECLARE
  has_constraint boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'patient_complaints'
      AND c.conname = 'patient_complaints_patient_complaint_uq'
  ) INTO has_constraint;

  IF has_constraint THEN
    EXECUTE '
      ALTER TABLE public.patient_complaints
      DROP CONSTRAINT IF EXISTS patient_complaints_patient_complaint_uq
    ';
  END IF;

  -- Restore partial unique index (original behavior)
  EXECUTE '
    CREATE UNIQUE INDEX IF NOT EXISTS patient_complaints_patient_complaint_uq
    ON public.patient_complaints (patient_id, complaint_id)
    WHERE complaint_id IS NOT NULL
  ';
END $$;

COMMIT;
