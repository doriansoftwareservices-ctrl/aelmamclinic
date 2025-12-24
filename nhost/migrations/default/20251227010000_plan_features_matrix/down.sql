-- Revert plan feature matrix + restore apply_plan_permissions

BEGIN;

-- Restore previous apply_plan_permissions behavior
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
  free_features text[] := ARRAY['dashboard','patients.new','patients.list','employees'];
BEGIN
  IF p_account IS NULL THEN
    RETURN;
  END IF;

  IF coalesce(p_plan, 'free') = 'free' THEN
    UPDATE public.account_feature_permissions
       SET allowed_features = free_features,
           can_create = true,
           can_update = true,
           can_delete = true
     WHERE account_id = p_account;
  ELSE
    UPDATE public.account_feature_permissions
       SET allowed_features = ARRAY[]::text[],
           can_create = true,
           can_update = true,
           can_delete = true
     WHERE account_id = p_account;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_plan_permissions(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_plan_permissions(uuid, text) TO public;

DROP FUNCTION IF EXISTS public.plan_allowed_features(text);
DROP TABLE IF EXISTS public.plan_features;

COMMIT;
