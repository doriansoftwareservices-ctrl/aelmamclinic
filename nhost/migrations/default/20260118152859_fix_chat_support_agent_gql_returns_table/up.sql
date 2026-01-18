-- Wrappers MUST return TABLE(...) so Hasura can track them

CREATE OR REPLACE FUNCTION public.chat_support_agent_gql()
RETURNS TABLE(user_uid uuid, display_name text)
LANGUAGE sql
STABLE
AS $$
  SELECT user_uid, display_name
  FROM public.chat_support_agent();
$$;

CREATE OR REPLACE FUNCTION public.chat_set_support_agent_gql(p_user_uid uuid, p_display_name text)
RETURNS TABLE(user_uid uuid, display_name text)
LANGUAGE sql
VOLATILE
AS $$
  SELECT user_uid, display_name
  FROM public.chat_set_support_agent(p_user_uid, p_display_name);
$$;

-- optional: drop the composite type if you created it earlier (won't fail if missing)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='chat_support_agent_result'
  ) THEN
    -- only drop if no function depends on it anymore
    BEGIN
      EXECUTE 'DROP TYPE public.chat_support_agent_result';
    EXCEPTION WHEN dependent_objects_still_exist THEN
      -- ignore if still referenced
      NULL;
    END;
  END IF;
END $$;
