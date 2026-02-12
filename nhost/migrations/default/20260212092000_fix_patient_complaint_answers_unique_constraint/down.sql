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
      AND t.relname = 'patient_complaint_answers'
      AND c.conname = 'patient_complaint_answers_uq'
  ) INTO has_constraint;

  IF has_constraint THEN
    EXECUTE '
      ALTER TABLE public.patient_complaint_answers
      DROP CONSTRAINT IF EXISTS patient_complaint_answers_uq
    ';
  END IF;

  -- Restore unique index (original behavior)
  EXECUTE '
    CREATE UNIQUE INDEX IF NOT EXISTS patient_complaint_answers_uq
    ON public.patient_complaint_answers (patient_complaint_id, question_id)
  ';
END $$;

COMMIT;
