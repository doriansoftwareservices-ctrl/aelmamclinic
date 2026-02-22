BEGIN;

DO $do$
BEGIN
  IF to_regclass('public.employees_salaries') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'employees_salaries'
        AND column_name = 'total_discounts'
    ) THEN
      EXECUTE 'ALTER TABLE public.employees_salaries ADD COLUMN total_discounts numeric DEFAULT 0';
    END IF;
  END IF;
END
$do$;

COMMIT;
