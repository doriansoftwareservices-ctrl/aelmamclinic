DO $$
BEGIN
  IF to_regclass('public.employees_salaries') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'employees_salaries'
        AND column_name = 'period_start'
    ) THEN
      ALTER TABLE public.employees_salaries
        DROP COLUMN period_start;
    END IF;

    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'employees_salaries'
        AND column_name = 'period_end'
    ) THEN
      ALTER TABLE public.employees_salaries
        DROP COLUMN period_end;
    END IF;
  END IF;
END $$;
