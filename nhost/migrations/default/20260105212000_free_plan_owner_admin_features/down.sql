BEGIN;

-- Revert FREE plan employees feature addition.
DELETE FROM public.plan_features
WHERE plan_code = 'free' AND feature_key = 'employees';

-- Restore plan_allowed_features fallback without employees for FREE.
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
      THEN ARRAY['dashboard','patients.new','patients.list']::text[]
    ELSE ARRAY[]::text[]
  END;
$$;
REVOKE ALL ON FUNCTION public.plan_allowed_features(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.plan_allowed_features(text) TO PUBLIC;

COMMIT;
