BEGIN;

-- Bonus critical fix: apply_plan_permissions currently writes allowed_features to itself
-- (nhost/migrations/default/20251227010000_plan_features_matrix/up.sql:67), so plan updates don't apply.
-- This patch fixes the variable assignment and aligns FREE feature list with employee gating.

-- Remove employees feature from FREE (employee creation is gated to paid plans elsewhere).
DELETE FROM public.plan_features
WHERE plan_code = 'free' AND feature_key = 'employees';

-- Recreate plan_allowed_features with correct FREE fallback.
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

-- Fix apply_plan_permissions assignment.
CREATE OR REPLACE FUNCTION public.apply_plan_permissions(
  p_account uuid,
  p_plan text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_allowed_features text[] := public.plan_allowed_features(p_plan);
BEGIN
  IF p_account IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.account_feature_permissions
     SET allowed_features = v_allowed_features,
         can_create = true,
         can_update = true,
         can_delete = true
   WHERE account_id = p_account;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_plan_permissions(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_plan_permissions(uuid, text) TO public;

COMMIT;
