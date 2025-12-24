-- Plan feature matrix (source of truth) + updated apply_plan_permissions

BEGIN;

-- 1) Plan features catalog (plan -> feature keys)
CREATE TABLE IF NOT EXISTS public.plan_features (
  plan_code   text NOT NULL REFERENCES public.subscription_plans(code) ON DELETE CASCADE,
  feature_key text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (plan_code, feature_key)
);

-- Seed FREE plan feature set (minimal access as requested)
INSERT INTO public.plan_features(plan_code, feature_key)
VALUES
  ('free', 'dashboard'),
  ('free', 'patients.new'),
  ('free', 'patients.list'),
  ('free', 'employees')
ON CONFLICT DO NOTHING;

-- 2) Helper: compute allowed feature list for a plan
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

-- 3) Update apply_plan_permissions to use plan_features matrix
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
  allowed_features text[] := public.plan_allowed_features(p_plan);
BEGIN
  IF p_account IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.account_feature_permissions
     SET allowed_features = allowed_features,
         can_create = true,
         can_update = true,
         can_delete = true
   WHERE account_id = p_account;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_plan_permissions(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_plan_permissions(uuid, text) TO public;

COMMIT;
