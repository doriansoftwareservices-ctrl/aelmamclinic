BEGIN;

DO $do$
BEGIN
  IF to_regclass('public.employees_salaries') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'employees_salaries'
        AND column_name = 'total_discounts'
    ) THEN
      EXECUTE 'ALTER TABLE public.employees_salaries DROP COLUMN total_discounts';
    END IF;
  END IF;
END
$do$;

COMMIT;
