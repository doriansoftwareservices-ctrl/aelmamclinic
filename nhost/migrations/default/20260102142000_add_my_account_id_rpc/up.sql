BEGIN;

-- Trackable RPC wrapper returning v_uuid_result for Hasura.
DROP FUNCTION IF EXISTS public.my_account_id_rpc();
DROP FUNCTION IF EXISTS public.my_account_id_rpc(json);

CREATE OR REPLACE FUNCTION public.my_account_id_rpc(hasura_session json)
RETURNS SETOF public.v_uuid_result
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT au.account_id AS id
  FROM public.account_users au
  WHERE au.user_uid = nullif(hasura_session->>'x-hasura-user-id','')::uuid
    AND coalesce(au.disabled, false) = false
  ORDER BY au.created_at DESC
  LIMIT 1
$$;

REVOKE ALL ON FUNCTION public.my_account_id_rpc(json) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_account_id_rpc(json) TO PUBLIC;

COMMIT;
