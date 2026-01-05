BEGIN;

REVOKE ALL ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO postgres';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nhost') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO nhost';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nhost_auth_admin') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO nhost_auth_admin';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'nhost_storage_admin') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.auth_set_user_claims(uuid, text, uuid) TO nhost_storage_admin';
  END IF;
END
$$;

COMMIT;
