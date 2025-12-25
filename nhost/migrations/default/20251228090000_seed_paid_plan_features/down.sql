-- Remove seeded paid-plan features

BEGIN;

DELETE FROM public.plan_features
WHERE plan_code IN ('month', 'year')
  AND feature_key IN (
    'dashboard',
    'patients.new',
    'patients.list',
    'returns',
    'employees',
    'payments',
    'lab_radiology',
    'charts',
    'repository',
    'prescriptions',
    'backup',
    'accounts',
    'chat',
    'audit.logs',
    'audit.permissions'
  );

COMMIT;
