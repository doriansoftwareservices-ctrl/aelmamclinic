BEGIN;

-- Remove paid-only features from plan_features
DELETE FROM public.plan_features
WHERE plan_code IN ('month','year')
  AND feature_key IN ('clinic.profile','employee.accounts');

-- Re-apply permissions to reflect removal
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT account_id, plan_code
    FROM public.account_subscriptions
    WHERE status = 'active'
      AND plan_code IN ('month','year')
  LOOP
    PERFORM public.apply_plan_permissions(r.account_id, r.plan_code);
  END LOOP;
END $$;

COMMIT;
