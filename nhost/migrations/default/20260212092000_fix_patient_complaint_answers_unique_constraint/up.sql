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

  IF NOT has_constraint THEN
    -- Remove unique index if it exists (Hasura on_conflict needs a constraint)
    IF EXISTS (
      SELECT 1
      FROM pg_class i
      JOIN pg_namespace n ON n.oid = i.relnamespace
      WHERE n.nspname = 'public'
        AND i.relname = 'patient_complaint_answers_uq'
        AND i.relkind = 'i'
    ) THEN
      EXECUTE 'DROP INDEX IF EXISTS public.patient_complaint_answers_uq';
    END IF;

    -- Create proper unique constraint for Hasura on_conflict
    EXECUTE '
      ALTER TABLE public.patient_complaint_answers
      ADD CONSTRAINT patient_complaint_answers_uq
      UNIQUE (patient_complaint_id, question_id)
    ';
  END IF;
END $$;

COMMIT;
