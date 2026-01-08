BEGIN;

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
