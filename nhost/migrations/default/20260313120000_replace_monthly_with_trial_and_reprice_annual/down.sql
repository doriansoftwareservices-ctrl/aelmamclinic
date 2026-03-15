BEGIN;

DROP VIEW IF EXISTS public.v_admin_arr_by_month;
DROP VIEW IF EXISTS public.v_admin_mrr_by_month;

DROP FUNCTION IF EXISTS public.create_trial_plan_request(json, text);

UPDATE public.subscription_plans
   SET is_active = true,
       price_usd = CASE code
         WHEN 'month' THEN 30
         WHEN 'month_plus' THEN 99
         WHEN 'month_pro' THEN 150
         WHEN 'year' THEN 350
         WHEN 'year_plus' THEN 999
         WHEN 'year_pro' THEN 1500
         ELSE price_usd
       END,
       updated_at = now()
 WHERE code IN ('month', 'month_plus', 'month_pro', 'year', 'year_plus', 'year_pro');

DELETE FROM public.plan_features
 WHERE plan_code = 'trial_month';

DELETE FROM public.subscription_plans
 WHERE code = 'trial_month';

DROP FUNCTION IF EXISTS public.admin_set_account_plan(uuid, text, text);

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

CREATE OR REPLACE VIEW public.v_admin_dashboard_payments AS
SELECT
  p.id AS payment_id,
  p.received_at,
  p.account_id,
  a.name AS account_name,
  p.plan_code,
  sp.name AS plan_name,
  p.amount AS amount_usd,
  pm.name AS payment_method,
  p.request_id,
  p.created_by,
  coalesce(au.email, sa.email, '') AS created_by_email
FROM public.subscription_payments p
JOIN public.accounts a ON a.id = p.account_id
LEFT JOIN public.subscription_plans sp ON sp.code = p.plan_code
LEFT JOIN public.payment_methods pm ON pm.id = p.payment_method_id
LEFT JOIN public.account_users au ON au.account_id = p.account_id AND au.user_uid = p.created_by
LEFT JOIN public.super_admins sa ON sa.user_uid = p.created_by;

CREATE OR REPLACE VIEW public.v_admin_dashboard_revenue_monthly AS
SELECT
  date_trunc('month', received_at) AS month,
  count(*) AS payments_count,
  round(sum(amount)::numeric, 2) AS total_amount_usd,
  round(avg(amount)::numeric, 2) AS avg_payment_usd
FROM public.subscription_payments
GROUP BY 1;

CREATE OR REPLACE FUNCTION public.admin_payment_stats()
RETURNS SETOF public.v_payment_stats
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    pm.id AS payment_method_id,
    pm.name AS payment_method_name,
    COALESCE(SUM(x.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM (
    SELECT payment_method_id, amount FROM public.subscription_payments
    UNION ALL
    SELECT payment_method_id, amount FROM public.employee_seat_payments
  ) x
  LEFT JOIN public.payment_methods pm
    ON pm.id = x.payment_method_id
  GROUP BY pm.id, pm.name
  ORDER BY total_amount DESC NULLS LAST;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_plan()
RETURNS SETOF public.v_payment_stats_by_plan
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    x.plan_code,
    COALESCE(SUM(x.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM (
    SELECT plan_code, amount, received_at FROM public.subscription_payments
    UNION ALL
    SELECT 'extra_seat'::text AS plan_code, amount, received_at
      FROM public.employee_seat_payments
  ) x
  GROUP BY x.plan_code
  ORDER BY total_amount DESC NULLS LAST;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_plan() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_day()
RETURNS SETOF public.v_payment_stats_by_day
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    date_trunc('day', x.received_at)::date AS day,
    COALESCE(SUM(x.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM (
    SELECT amount, received_at FROM public.subscription_payments
    UNION ALL
    SELECT amount, received_at FROM public.employee_seat_payments
  ) x
  GROUP BY day
  ORDER BY day DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_day() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_day() TO public;

CREATE OR REPLACE FUNCTION public.admin_payment_stats_by_month()
RETURNS SETOF public.v_payment_stats_by_month
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.fn_is_super_admin() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    date_trunc('month', x.received_at)::date AS month,
    COALESCE(SUM(x.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM (
    SELECT amount, received_at FROM public.subscription_payments
    UNION ALL
    SELECT amount, received_at FROM public.employee_seat_payments
  ) x
  GROUP BY month
  ORDER BY month DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_month() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_month() TO public;

COMMIT;
