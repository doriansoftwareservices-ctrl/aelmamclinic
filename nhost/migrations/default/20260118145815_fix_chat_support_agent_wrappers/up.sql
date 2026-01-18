-- Trackable composite type
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='chat_support_agent_result'
  ) THEN
    CREATE TYPE public.chat_support_agent_result AS (
      user_uid uuid,
      display_name text
    );
  END IF;
END$$;

-- Trackable wrappers (SETOF composite)
CREATE OR REPLACE FUNCTION public.chat_support_agent_gql()
RETURNS SETOF public.chat_support_agent_result
LANGUAGE sql
STABLE
AS $$
  SELECT user_uid, display_name
  FROM public.chat_support_agent();
$$;

CREATE OR REPLACE FUNCTION public.chat_set_support_agent_gql(p_user_uid uuid, p_display_name text)
RETURNS SETOF public.chat_support_agent_result
LANGUAGE sql
VOLATILE
AS $$
  SELECT user_uid, display_name
  FROM public.chat_set_support_agent(p_user_uid, p_display_name);
$$;
