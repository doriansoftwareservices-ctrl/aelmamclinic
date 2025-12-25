-- Seed feature matrix for paid plans (month/year)

BEGIN;

INSERT INTO public.plan_features(plan_code, feature_key)
VALUES
  ('month', 'dashboard'),
  ('month', 'patients.new'),
  ('month', 'patients.list'),
  ('month', 'returns'),
  ('month', 'employees'),
  ('month', 'payments'),
  ('month', 'lab_radiology'),
  ('month', 'charts'),
  ('month', 'repository'),
  ('month', 'prescriptions'),
  ('month', 'backup'),
  ('month', 'accounts'),
  ('month', 'chat'),
  ('month', 'audit.logs'),
  ('month', 'audit.permissions'),
  ('year', 'dashboard'),
  ('year', 'patients.new'),
  ('year', 'patients.list'),
  ('year', 'returns'),
  ('year', 'employees'),
  ('year', 'payments'),
  ('year', 'lab_radiology'),
  ('year', 'charts'),
  ('year', 'repository'),
  ('year', 'prescriptions'),
  ('year', 'backup'),
  ('year', 'accounts'),
  ('year', 'chat'),
  ('year', 'audit.logs'),
  ('year', 'audit.permissions')
ON CONFLICT DO NOTHING;

COMMIT;
