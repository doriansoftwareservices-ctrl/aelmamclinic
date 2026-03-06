ALTER TABLE public.patients
ADD COLUMN IF NOT EXISTS collateral text;
