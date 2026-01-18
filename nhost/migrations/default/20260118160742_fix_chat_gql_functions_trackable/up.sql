BEGIN;

-- Result table ONLY for Hasura function return type (empty table pattern)
CREATE TABLE IF NOT EXISTS public.chat_support_agent_gql_result (
  user_uid uuid,
  display_name text
);

-- Drop old funcs (cannot change return type without dropping)
DROP FUNCTION IF EXISTS public.chat_support_agent_gql();
DROP FUNCTION IF EXISTS public.chat_set_support_agent_gql(uuid, text);

-- Recreate funcs returning SETOF tracked table
CREATE FUNCTION public.chat_support_agent_gql()
RETURNS SETOF public.chat_support_agent_gql_result
LANGUAGE sql
STABLE
AS $$
  SELECT user_uid, display_name
  FROM public.chat_support_agent();
$$;

CREATE FUNCTION public.chat_set_support_agent_gql(p_user_uid uuid, p_display_name text)
RETURNS SETOF public.chat_support_agent_gql_result
LANGUAGE sql
VOLATILE
AS $$
  SELECT user_uid, display_name
  FROM public.chat_set_support_agent(p_user_uid, p_display_name);
$$;

COMMIT;
