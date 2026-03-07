DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'financial_logs_patient_id_fkey'
  ) THEN
    ALTER TABLE public.financial_logs
      DROP CONSTRAINT financial_logs_patient_id_fkey;
  END IF;
END $$;

DROP INDEX IF EXISTS public.idx_financial_logs_patient_id;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'financial_logs'
      AND column_name = 'patient_id'
  ) THEN
    ALTER TABLE public.financial_logs
      DROP COLUMN patient_id;
  END IF;
END $$;
