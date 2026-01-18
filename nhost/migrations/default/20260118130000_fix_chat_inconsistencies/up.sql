BEGIN;

-- Ensure chat_conversations has id column + PK
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
      EXECUTE 'UPDATE public.chat_conversations SET id = gen_random_uuid() WHERE id IS NULL';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_constraint
      WHERE conrelid = 'public.chat_conversations'::regclass
        AND contype = 'p'
    ) THEN
      EXECUTE 'ALTER TABLE public.chat_conversations ADD CONSTRAINT chat_conversations_pkey PRIMARY KEY (id)';
    END IF;
  END IF;
END $$;

-- Ensure chat_participants has conversation_id column + FK
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

-- Deduplicate chat_attachments.message_id FK (Hasura requires a single FK per relationship)
DO $$
DECLARE
  v_keep text;
  r record;
BEGIN
  IF to_regclass('public.chat_attachments') IS NOT NULL
     AND to_regclass('public.chat_messages') IS NOT NULL THEN
    SELECT c.conname
      INTO v_keep
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_class f ON f.oid = c.confrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'chat_attachments'
      AND f.relname = 'chat_messages'
      AND c.contype = 'f'
      AND c.conkey = ARRAY[
        (SELECT attnum
           FROM pg_attribute
          WHERE attrelid = t.oid AND attname = 'message_id')
      ]
    ORDER BY c.conname
    LIMIT 1;

    FOR r IN
      SELECT c.conname
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_class f ON f.oid = c.confrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE n.nspname = 'public'
        AND t.relname = 'chat_attachments'
        AND f.relname = 'chat_messages'
        AND c.contype = 'f'
        AND c.conkey = ARRAY[
          (SELECT attnum
             FROM pg_attribute
            WHERE attrelid = t.oid AND attname = 'message_id')
        ]
    LOOP
      IF v_keep IS NOT NULL AND r.conname <> v_keep THEN
        EXECUTE format('ALTER TABLE public.chat_attachments DROP CONSTRAINT %I', r.conname);
      END IF;
    END LOOP;

    IF v_keep IS NULL THEN
      EXECUTE 'ALTER TABLE public.chat_attachments
               ADD CONSTRAINT chat_attachments_message_id_fkey
               FOREIGN KEY (message_id) REFERENCES public.chat_messages(id)
               ON DELETE CASCADE';
    END IF;
  END IF;
END $$;

-- Ensure support functions return TABLE for Hasura tracking
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
