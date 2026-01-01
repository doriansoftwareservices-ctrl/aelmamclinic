BEGIN;

DROP TRIGGER IF EXISTS seed_account_feature_permissions ON public.account_users;
DROP FUNCTION IF EXISTS public.trg_seed_account_feature_permissions();

COMMIT;
