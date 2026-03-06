DO $$
BEGIN
  IF to_regclass('public.employees_salaries') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'employees_salaries'
        AND column_name = 'period_start'
    ) THEN
      ALTER TABLE public.employees_salaries
        ADD COLUMN period_start timestamptz;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'employees_salaries'
        AND column_name = 'period_end'
    ) THEN
      ALTER TABLE public.employees_salaries
        ADD COLUMN period_end timestamptz;
    END IF;
  END IF;
END $$;
