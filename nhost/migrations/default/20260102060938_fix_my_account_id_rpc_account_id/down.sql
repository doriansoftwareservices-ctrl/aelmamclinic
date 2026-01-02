BEGIN;

DROP FUNCTION IF EXISTS public.my_account_id_rpc();
DROP VIEW IF EXISTS public.v_account_id_result;

CREATE OR REPLACE FUNCTION public.my_account_id_rpc()
RETURNS SETOF public.v_uuid_result
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.my_account_id() AS id
$$;

REVOKE ALL ON FUNCTION public.my_account_id_rpc() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id_rpc() TO PUBLIC;

COMMIT;
