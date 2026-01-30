BEGIN;

-- Ensure paid plans include clinic profile + employee accounts features
INSERT INTO public.plan_features(plan_code, feature_key)
VALUES
  ('month', 'clinic.profile'),
  ('month', 'employee.accounts'),
  ('year',  'clinic.profile'),
  ('year',  'employee.accounts')
ON CONFLICT DO NOTHING;

-- Re-apply permissions for active paid subscriptions
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
