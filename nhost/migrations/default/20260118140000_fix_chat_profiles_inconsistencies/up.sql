BEGIN;

-- Ensure profiles.id exists (some environments used user_uid)
DO $$
BEGIN
  IF to_regclass('public.profiles') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'profiles'
        AND column_name = 'id'
    ) THEN
      EXECUTE 'ALTER TABLE public.profiles ADD COLUMN id uuid';
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'profiles'
          AND column_name = 'user_uid'
      ) THEN
        EXECUTE 'UPDATE public.profiles SET id = user_uid WHERE id IS NULL';
      ELSIF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'profiles'
          AND column_name = 'user_id'
      ) THEN
        EXECUTE 'UPDATE public.profiles SET id = user_id WHERE id IS NULL';
      END IF;
    END IF;
  END IF;
END $$;

-- Ensure chat_conversations.id exists
DO $$
BEGIN
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_conversations'
        AND column_name = 'id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_conversations ADD COLUMN id uuid';
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'chat_conversations'
          AND column_name = 'conversation_id'
      ) THEN
        EXECUTE 'UPDATE public.chat_conversations SET id = conversation_id WHERE id IS NULL';
      ELSIF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'chat_conversations'
          AND column_name = 'conversation_uuid'
      ) THEN
        EXECUTE 'UPDATE public.chat_conversations SET id = conversation_uuid WHERE id IS NULL';
      END IF;
      EXECUTE 'UPDATE public.chat_conversations SET id = gen_random_uuid() WHERE id IS NULL';
    END IF;
  END IF;
END $$;

-- Ensure unique index on chat_conversations.id (without replacing PK)
DO $$
BEGIN
  IF to_regclass('public.chat_conversations') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indrelid
      WHERE c.relname = 'chat_conversations'
        AND i.indisunique
        AND i.indkey = ARRAY[
          (SELECT attnum
             FROM pg_attribute
            WHERE attrelid = c.oid AND attname = 'id')
        ]
    ) THEN
      EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS chat_conversations_id_key ON public.chat_conversations(id)';
    END IF;
  END IF;
END $$;

-- Ensure chat_participants.conversation_id exists + FK
DO $$
BEGIN
  IF to_regclass('public.chat_participants') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'chat_participants'
        AND column_name = 'conversation_id'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_participants ADD COLUMN conversation_id uuid';
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'chat_participants'
          AND column_name = 'conversation_uuid'
      ) THEN
        EXECUTE 'UPDATE public.chat_participants SET conversation_id = conversation_uuid WHERE conversation_id IS NULL';
      ELSIF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'chat_participants'
          AND column_name = 'conv_id'
      ) THEN
        EXECUTE 'UPDATE public.chat_participants SET conversation_id = conv_id WHERE conversation_id IS NULL';
      END IF;
    END IF;

    IF to_regclass('public.chat_conversations') IS NOT NULL
       AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chat_participants_conversation_id_fkey'
      ) THEN
      EXECUTE 'ALTER TABLE public.chat_participants
               ADD CONSTRAINT chat_participants_conversation_id_fkey
               FOREIGN KEY (conversation_id) REFERENCES public.chat_conversations(id)
               ON DELETE CASCADE';
    END IF;
  END IF;
END $$;

-- Ensure support functions are tracked as TABLE-returning
DROP FUNCTION IF EXISTS public.chat_support_agent();
CREATE OR REPLACE FUNCTION public.chat_support_agent()
RETURNS TABLE(user_uid uuid, display_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
SET row_security TO 'off'
AS $$
  SELECT user_uid, display_name
  FROM public.chat_support_agents
  WHERE is_active = true
  ORDER BY updated_at DESC
  LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.chat_set_support_agent(uuid, text);
CREATE OR REPLACE FUNCTION public.chat_set_support_agent(
  p_user_uid uuid,
  p_display_name text DEFAULT 'خدمة العملاء'
)
RETURNS TABLE(user_uid uuid, display_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
SET row_security TO 'off'
AS $$
DECLARE
  v_uid uuid;
  v_name text;
BEGIN
  IF NOT public.fn_is_super_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_uid := p_user_uid;
  v_name := COALESCE(NULLIF(trim(p_display_name), ''), 'خدمة العملاء');

  UPDATE public.chat_support_agents
  SET is_active = false,
      updated_at = now()
  WHERE is_active = true;

  INSERT INTO public.chat_support_agents(
    user_uid,
    display_name,
    is_active,
    created_by,
    updated_at
  ) VALUES (
    v_uid,
    v_name,
    true,
    NULLIF(public.request_uid_text(), '')::uuid,
    now()
  )
  ON CONFLICT (user_uid)
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    is_active = true,
    updated_at = now();

  RETURN QUERY
  SELECT user_uid, display_name
  FROM public.chat_support_agents
  WHERE is_active = true
  ORDER BY updated_at DESC
  LIMIT 1;
END;
$$;

COMMIT;
