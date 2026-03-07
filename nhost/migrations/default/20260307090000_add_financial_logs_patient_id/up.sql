DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'financial_logs'
      AND column_name = 'patient_id'
  ) THEN
    ALTER TABLE public.financial_logs
      ADD COLUMN patient_id uuid;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'financial_logs_patient_id_fkey'
  ) THEN
    ALTER TABLE public.financial_logs
      ADD CONSTRAINT financial_logs_patient_id_fkey
      FOREIGN KEY (patient_id)
      REFERENCES public.patients(id)
      ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_financial_logs_patient_id
  ON public.financial_logs(patient_id);
