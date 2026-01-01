BEGIN;

-- Ensure allow_all exists.
ALTER TABLE public.account_feature_permissions
  ADD COLUMN IF NOT EXISTS allow_all boolean NOT NULL DEFAULT false;

-- Seed missing rows for existing account_users.
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
  CASE WHEN lower(coalesce(au.role,'')) IN ('owner','admin') THEN true ELSE false END,
  ARRAY[]::text[],
  CASE WHEN lower(coalesce(au.role,'')) IN ('owner','admin') THEN true ELSE false END,
  CASE WHEN lower(coalesce(au.role,'')) IN ('owner','admin') THEN true ELSE false END,
  CASE WHEN lower(coalesce(au.role,'')) IN ('owner','admin') THEN true ELSE false END
FROM public.account_users au
WHERE coalesce(au.disabled,false) = false
  AND NOT EXISTS (
    SELECT 1
    FROM public.account_feature_permissions fp
    WHERE fp.account_id = au.account_id
      AND fp.user_uid = au.user_uid
  );

-- Trigger function to seed on new account_users rows.
CREATE OR REPLACE FUNCTION public.trg_seed_account_feature_permissions()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.account_feature_permissions(
    account_id, user_uid, allow_all, allowed_features, can_create, can_update, can_delete
  ) VALUES (
    NEW.account_id,
    NEW.user_uid,
    CASE WHEN lower(coalesce(NEW.role,'')) IN ('owner','admin') THEN true ELSE false END,
    ARRAY[]::text[],
    CASE WHEN lower(coalesce(NEW.role,'')) IN ('owner','admin') THEN true ELSE false END,
    CASE WHEN lower(coalesce(NEW.role,'')) IN ('owner','admin') THEN true ELSE false END,
    CASE WHEN lower(coalesce(NEW.role,'')) IN ('owner','admin') THEN true ELSE false END
  )
  ON CONFLICT (account_id, user_uid) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS seed_account_feature_permissions ON public.account_users;
CREATE TRIGGER seed_account_feature_permissions
AFTER INSERT ON public.account_users
FOR EACH ROW
EXECUTE FUNCTION public.trg_seed_account_feature_permissions();

COMMIT;
