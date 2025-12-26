-- Use view-backed return types for admin payment stats (Hasura tracking).

BEGIN;

CREATE OR REPLACE VIEW public.v_payment_stats AS
SELECT
  NULL::uuid AS payment_method_id,
  NULL::text AS payment_method_name,
  NULL::numeric AS total_amount,
  NULL::bigint AS payments_count
WHERE false;

CREATE OR REPLACE VIEW public.v_payment_stats_by_plan AS
SELECT
  NULL::text AS plan_code,
  NULL::numeric AS total_amount,
  NULL::bigint AS payments_count
WHERE false;

CREATE OR REPLACE VIEW public.v_payment_stats_by_day AS
SELECT
  NULL::date AS day,
  NULL::numeric AS total_amount,
  NULL::bigint AS payments_count
WHERE false;

CREATE OR REPLACE VIEW public.v_payment_stats_by_month AS
SELECT
  NULL::date AS month,
  NULL::numeric AS total_amount,
  NULL::bigint AS payments_count
WHERE false;

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
    COALESCE(SUM(sp.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM public.subscription_payments sp
  LEFT JOIN public.payment_methods pm
    ON pm.id = sp.payment_method_id
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
    sp.plan_code,
    COALESCE(SUM(sp.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM public.subscription_payments sp
  GROUP BY sp.plan_code
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
    date_trunc('day', sp.received_at)::date AS day,
    COALESCE(SUM(sp.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM public.subscription_payments sp
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
    date_trunc('month', sp.received_at)::date AS month,
    COALESCE(SUM(sp.amount), 0) AS total_amount,
    COUNT(*) AS payments_count
  FROM public.subscription_payments sp
  GROUP BY month
  ORDER BY month DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_stats_by_month() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_payment_stats_by_month() TO public;

COMMIT;
