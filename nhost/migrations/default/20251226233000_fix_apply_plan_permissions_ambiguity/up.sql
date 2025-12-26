BEGIN;

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
