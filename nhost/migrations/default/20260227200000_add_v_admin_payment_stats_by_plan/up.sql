BEGIN;

CREATE OR REPLACE VIEW public.v_admin_payment_stats_by_plan AS
SELECT
  x.plan_code,
  COALESCE(SUM(x.amount), 0)::numeric AS total_amount,
  COUNT(*)::bigint AS payments_count
FROM (
  SELECT plan_code, amount
  FROM public.subscription_payments
  UNION ALL
  SELECT 'extra_seat'::text AS plan_code, amount
  FROM public.employee_seat_payments
) x
GROUP BY x.plan_code;

COMMIT;
