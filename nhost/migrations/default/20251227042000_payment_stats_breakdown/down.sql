BEGIN;

DROP FUNCTION IF EXISTS public.admin_payment_stats_by_month();
DROP FUNCTION IF EXISTS public.admin_payment_stats_by_day();
DROP FUNCTION IF EXISTS public.admin_payment_stats_by_plan();

COMMIT;
