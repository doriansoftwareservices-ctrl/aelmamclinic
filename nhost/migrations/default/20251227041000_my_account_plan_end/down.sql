-- Revert my_account_plan to plan_code only

BEGIN;

CREATE OR REPLACE VIEW public.v_my_account_plan AS
SELECT NULL::text AS plan_code
WHERE false;

DROP FUNCTION IF EXISTS public.my_account_plan();
CREATE OR REPLACE FUNCTION public.my_account_plan()
RETURNS SETOF public.v_my_account_plan
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH acc AS (
    SELECT account_id
    FROM public.my_account_id()
    LIMIT 1
  ),
  active_sub AS (
    SELECT s.plan_code
    FROM public.account_subscriptions s
    JOIN acc ON acc.account_id = s.account_id
    WHERE s.status = 'active'
      AND (s.end_at IS NULL OR s.end_at > now())
    ORDER BY s.created_at DESC
    LIMIT 1
  )
  SELECT COALESCE((SELECT plan_code FROM active_sub), 'free') AS plan_code;
$$;
REVOKE ALL ON FUNCTION public.my_account_plan() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_plan() TO PUBLIC;

COMMIT;
