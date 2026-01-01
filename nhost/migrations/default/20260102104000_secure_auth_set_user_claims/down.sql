BEGIN;

GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO PUBLIC;

COMMIT;
