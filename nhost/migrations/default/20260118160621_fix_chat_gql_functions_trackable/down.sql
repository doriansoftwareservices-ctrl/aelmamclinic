BEGIN;
DROP FUNCTION IF EXISTS public.chat_support_agent_gql();
DROP FUNCTION IF EXISTS public.chat_set_support_agent_gql(uuid, text);
DROP TABLE IF EXISTS public.chat_support_agent_gql_result;
COMMIT;
