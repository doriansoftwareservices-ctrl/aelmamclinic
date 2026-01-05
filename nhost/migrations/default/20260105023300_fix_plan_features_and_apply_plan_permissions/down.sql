BEGIN;

-- Partial rollback: re-add FREE employees feature if desired.
INSERT INTO public.plan_features(plan_code, feature_key)
VALUES ('free', 'employees')
ON CONFLICT DO NOTHING;

COMMIT;
