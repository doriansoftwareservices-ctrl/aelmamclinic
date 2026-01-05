BEGIN;

-- Ensure FREE plan includes employees feature for owner/admin access.
INSERT INTO public.plan_features (plan_code, feature_key)
SELECT 'free', 'employees'
WHERE NOT EXISTS (
  SELECT 1 FROM public.plan_features
  WHERE plan_code = 'free' AND feature_key = 'employees'
);

-- Update plan_allowed_features fallback to include employees for FREE.
CREATE OR REPLACE FUNCTION public.plan_allowed_features(p_plan text)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH normalized AS (
    SELECT lower(coalesce(p_plan, 'free')) AS code
  ),
  explicit AS (
    SELECT pf.feature_key
    FROM public.plan_features pf
    JOIN normalized n ON pf.plan_code = n.code
  )
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM explicit)
      THEN ARRAY(SELECT feature_key FROM explicit ORDER BY feature_key)
    WHEN (SELECT code FROM normalized) = 'free'
      THEN ARRAY['dashboard','patients.new','patients.list','employees']::text[]
    ELSE ARRAY[]::text[]
  END;
$$;
REVOKE ALL ON FUNCTION public.plan_allowed_features(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.plan_allowed_features(text) TO PUBLIC;

-- Refresh FREE accounts permissions to include employees feature.
UPDATE public.account_feature_permissions afp
   SET allowed_features = public.plan_allowed_features('free')
 WHERE afp.account_id IN (
   SELECT a.id
   FROM public.accounts a
   WHERE NOT EXISTS (
     SELECT 1
     FROM public.account_subscriptions s
     WHERE s.account_id = a.id
       AND s.status = 'active'
       AND lower(coalesce(s.plan_code, 'free')) <> 'free'
   )
 );

COMMIT;
