CREATE OR REPLACE FUNCTION public.my_account_plan()
RETURNS SETOF public.v_my_account_plan
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH acc AS (
    SELECT (
      SELECT account_id
      FROM public.my_account_id(
        coalesce(current_setting('request.jwt.claims', true), '{}')::json
      )
      LIMIT 1
    ) AS account_id
  ),
  active_sub AS (
    SELECT s.plan_code, s.end_at
    FROM public.account_subscriptions s
    JOIN public.subscription_plans p ON p.code = s.plan_code
    JOIN acc ON acc.account_id = s.account_id
    WHERE s.status = 'active'
      AND (
        s.end_at IS NULL OR
        (s.end_at + (coalesce(p.grace_days, 0)::text || ' days')::interval) > now()
      )
    ORDER BY s.created_at DESC
    LIMIT 1
  )
  SELECT
    COALESCE((SELECT plan_code FROM active_sub), 'free') AS plan_code,
    (SELECT end_at FROM active_sub) AS plan_end_at;
$$;

REVOKE ALL ON FUNCTION public.my_account_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_plan() TO PUBLIC;
