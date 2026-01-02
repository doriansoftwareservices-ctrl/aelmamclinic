BEGIN;

CREATE OR REPLACE VIEW public.v_account_id_result AS
SELECT NULL::uuid AS account_id
WHERE false;

DROP FUNCTION IF EXISTS public.my_account_id_rpc();
CREATE OR REPLACE FUNCTION public.my_account_id_rpc()
RETURNS SETOF public.v_account_id_result
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.my_account_id() AS account_id
$$;

REVOKE ALL ON FUNCTION public.my_account_id_rpc() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id_rpc() TO PUBLIC;

COMMIT;
