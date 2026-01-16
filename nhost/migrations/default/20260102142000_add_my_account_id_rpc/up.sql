BEGIN;

-- Trackable RPC wrapper returning v_uuid_result for Hasura.
DROP FUNCTION IF EXISTS public.my_account_id_rpc();

CREATE OR REPLACE FUNCTION public.my_account_id_rpc(hasura_session json)
RETURNS SETOF public.v_uuid_result
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (
    SELECT account_id
    FROM public.my_account_id(hasura_session)
    LIMIT 1
  ) AS id
$$;

REVOKE ALL ON FUNCTION public.my_account_id_rpc(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id_rpc(json) TO PUBLIC;

COMMIT;
