BEGIN;

CREATE OR REPLACE VIEW public.active_account_feature_access
WITH (security_barrier = true)
AS
SELECT
  au.account_id,
  au.user_uid,
  afp.allow_all,
  afp.allowed_features
FROM public.account_users AS au
JOIN public.accounts AS a
  ON a.id = au.account_id
JOIN auth.users AS u
  ON u.id = au.user_uid
JOIN public.account_feature_permissions AS afp
  ON afp.account_id = au.account_id
 AND afp.user_uid = au.user_uid
WHERE au.disabled IS DISTINCT FROM true
  AND a.frozen IS DISTINCT FROM true
  AND u.disabled IS DISTINCT FROM true;

CREATE OR REPLACE VIEW public.active_superadmin_account_access
WITH (security_barrier = true)
AS
SELECT
  a.id AS account_id,
  sa.user_uid
FROM public.accounts AS a
CROSS JOIN public.super_admins AS sa
JOIN auth.users AS u
  ON u.id = sa.user_uid
WHERE a.frozen IS DISTINCT FROM true
  AND sa.disabled IS DISTINCT FROM true
  AND u.disabled IS DISTINCT FROM true;

COMMENT ON VIEW public.active_account_feature_access IS
  'Correlated Hasura authorization projection; not an application data API.';
COMMENT ON VIEW public.active_superadmin_account_access IS
  'Correlated active-superadmin authorization projection by unfrozen account.';

COMMIT;
