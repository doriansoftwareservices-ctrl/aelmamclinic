BEGIN;

-- Backfill missing feature-permission rows (deny-by-default for disabled).
INSERT INTO public.account_feature_permissions(
  account_id,
  user_uid,
  allow_all,
  allowed_features,
  can_create,
  can_update,
  can_delete
)
SELECT
  au.account_id,
  au.user_uid,
  CASE
    WHEN coalesce(au.disabled, false) = true THEN false
    WHEN lower(coalesce(au.role,'')) IN ('owner','admin') THEN true
    ELSE false
  END,
  ARRAY[]::text[],
  CASE
    WHEN coalesce(au.disabled, false) = true THEN false
    WHEN lower(coalesce(au.role,'')) IN ('owner','admin') THEN true
    ELSE false
  END,
  CASE
    WHEN coalesce(au.disabled, false) = true THEN false
    WHEN lower(coalesce(au.role,'')) IN ('owner','admin') THEN true
    ELSE false
  END,
  CASE
    WHEN coalesce(au.disabled, false) = true THEN false
    WHEN lower(coalesce(au.role,'')) IN ('owner','admin') THEN true
    ELSE false
  END
FROM public.account_users au
WHERE NOT EXISTS (
  SELECT 1
  FROM public.account_feature_permissions fp
  WHERE fp.account_id = au.account_id
    AND fp.user_uid = au.user_uid
);

COMMIT;
