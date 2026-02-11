BEGIN;

DROP TRIGGER IF EXISTS trg_normalize_auth_users_json ON auth.users;
DROP FUNCTION IF EXISTS public.trg_normalize_auth_users_json();
DROP FUNCTION IF EXISTS public.normalize_auth_jsonb(jsonb);

COMMIT;
