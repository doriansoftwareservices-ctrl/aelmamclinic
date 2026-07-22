BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Nhost owns and manages storage.files. Attachment ownership is therefore
-- stored in an application-owned public table instead of custom columns,
-- policies, triggers, or role switching on storage.files.
CREATE TABLE IF NOT EXISTS public.chat_attachment_file_ownership (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id uuid,
  bucket_id text NOT NULL,
  file_name text NOT NULL,
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  uploaded_by_user_id uuid,
  security_state text NOT NULL DEFAULT 'active',
  source text NOT NULL DEFAULT 'function',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chat_attachment_file_ownership_bucket_check
    CHECK (bucket_id IN ('chat-images', 'chat-attachments')),
  CONSTRAINT chat_attachment_file_ownership_state_check
    CHECK (security_state IN ('active', 'quarantined')),
  CONSTRAINT chat_attachment_file_ownership_name_check
    CHECK (btrim(file_name) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_attachment_file_ownership_file_id
  ON public.chat_attachment_file_ownership(file_id)
  WHERE file_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_attachment_file_ownership_bucket_name
  ON public.chat_attachment_file_ownership(bucket_id, file_name);

CREATE INDEX IF NOT EXISTS idx_chat_attachment_file_ownership_scope
  ON public.chat_attachment_file_ownership(
    account_id,
    conversation_id,
    message_id,
    security_state
  );

CREATE TABLE IF NOT EXISTS public.chat_attachment_quarantine (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  file_id uuid,
  bucket_id text NOT NULL,
  file_name text NOT NULL,
  reason_code text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  discovered_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolution_note text
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_attachment_quarantine_identity
  ON public.chat_attachment_quarantine(
    bucket_id,
    file_name,
    reason_code
  )
  WHERE resolved_at IS NULL;

CREATE OR REPLACE FUNCTION public.assert_chat_attachment_file_ownership()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  expected_account_id uuid;
  expected_conversation_id uuid;
BEGIN
  SELECT c.account_id, m.conversation_id
    INTO expected_account_id, expected_conversation_id
  FROM public.chat_messages m
  JOIN public.chat_conversations c ON c.id = m.conversation_id
  WHERE m.id = NEW.message_id
  LIMIT 1;

  IF expected_account_id IS NULL
     OR expected_conversation_id IS NULL
     OR expected_account_id IS DISTINCT FROM NEW.account_id
     OR expected_conversation_id IS DISTINCT FROM NEW.conversation_id THEN
    RAISE EXCEPTION 'chat attachment ownership scope mismatch'
      USING ERRCODE = '23514';
  END IF;

  NEW.file_name := btrim(NEW.file_name);
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS chat_attachment_file_ownership_guard
  ON public.chat_attachment_file_ownership;

CREATE TRIGGER chat_attachment_file_ownership_guard
BEFORE INSERT OR UPDATE
ON public.chat_attachment_file_ownership
FOR EACH ROW
EXECUTE FUNCTION public.assert_chat_attachment_file_ownership();

CREATE OR REPLACE FUNCTION public.claim_chat_attachment_file(
  p_file_id uuid,
  p_bucket_id text,
  p_file_name text,
  p_account_id uuid,
  p_conversation_id uuid,
  p_message_id uuid,
  p_uploaded_by_user_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  existing public.chat_attachment_file_ownership%ROWTYPE;
  normalized_name text := btrim(COALESCE(p_file_name, ''));
BEGIN
  IF p_file_id IS NULL
     OR p_account_id IS NULL
     OR p_conversation_id IS NULL
     OR p_message_id IS NULL
     OR p_uploaded_by_user_id IS NULL
     OR normalized_name = ''
     OR p_bucket_id NOT IN ('chat-images', 'chat-attachments') THEN
    RETURN 'invalid_input';
  END IF;

  PERFORM 1
  FROM public.chat_messages m
  JOIN public.chat_conversations c ON c.id = m.conversation_id
  WHERE m.id = p_message_id
    AND m.conversation_id = p_conversation_id
    AND c.account_id = p_account_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN 'invalid_scope';
  END IF;

  SELECT o.*
    INTO existing
  FROM public.chat_attachment_file_ownership o
  WHERE o.file_id = p_file_id
     OR (o.bucket_id = p_bucket_id AND o.file_name = normalized_name)
  ORDER BY CASE WHEN o.file_id = p_file_id THEN 0 ELSE 1 END
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    IF existing.account_id = p_account_id
       AND existing.conversation_id = p_conversation_id
       AND existing.message_id = p_message_id
       AND existing.bucket_id = p_bucket_id
       AND existing.file_name = normalized_name
       AND (existing.file_id IS NULL OR existing.file_id = p_file_id)
       AND (
         existing.uploaded_by_user_id IS NULL
         OR existing.uploaded_by_user_id = p_uploaded_by_user_id
       ) THEN
      UPDATE public.chat_attachment_file_ownership
      SET file_id = COALESCE(file_id, p_file_id),
          uploaded_by_user_id = COALESCE(uploaded_by_user_id, p_uploaded_by_user_id),
          security_state = 'active',
          updated_at = now()
      WHERE id = existing.id;
      RETURN 'linked';
    END IF;
    RETURN 'conflict';
  END IF;

  BEGIN
    INSERT INTO public.chat_attachment_file_ownership(
      file_id,
      bucket_id,
      file_name,
      account_id,
      conversation_id,
      message_id,
      uploaded_by_user_id,
      security_state,
      source
    ) VALUES (
      p_file_id,
      p_bucket_id,
      normalized_name,
      p_account_id,
      p_conversation_id,
      p_message_id,
      p_uploaded_by_user_id,
      'active',
      'function'
    );
    RETURN 'linked';
  EXCEPTION WHEN unique_violation THEN
    SELECT o.*
      INTO existing
    FROM public.chat_attachment_file_ownership o
    WHERE o.file_id = p_file_id
       OR (o.bucket_id = p_bucket_id AND o.file_name = normalized_name)
    ORDER BY CASE WHEN o.file_id = p_file_id THEN 0 ELSE 1 END
    LIMIT 1;

    IF FOUND
       AND existing.account_id = p_account_id
       AND existing.conversation_id = p_conversation_id
       AND existing.message_id = p_message_id
       AND existing.bucket_id = p_bucket_id
       AND existing.file_name = normalized_name
       AND (existing.file_id IS NULL OR existing.file_id = p_file_id) THEN
      RETURN 'linked';
    END IF;
    RETURN 'conflict';
  END;
END;
$function$;

REVOKE ALL ON TABLE public.chat_attachment_file_ownership FROM PUBLIC;
REVOKE ALL ON TABLE public.chat_attachment_quarantine FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_chat_attachment_file(
  uuid, text, text, uuid, uuid, uuid, uuid
) FROM PUBLIC;

-- Safe legacy backfill. It relies only on application-owned chat tables and
-- accepts both historical path formats: storage file UUID or object name.
INSERT INTO public.chat_attachment_file_ownership(
  file_id,
  bucket_id,
  file_name,
  account_id,
  conversation_id,
  message_id,
  uploaded_by_user_id,
  security_state,
  source
)
SELECT
  CASE
    WHEN a.path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    THEN a.path::uuid
    ELSE NULL
  END,
  CASE
    WHEN a.bucket IN ('chat-images', 'chat-attachments') THEN a.bucket
    ELSE 'chat-images'
  END,
  btrim(a.path),
  c.account_id,
  m.conversation_id,
  a.message_id,
  m.sender_uid,
  'active',
  'legacy_chat_attachments'
FROM public.chat_attachments a
JOIN public.chat_messages m ON m.id = a.message_id
JOIN public.chat_conversations c ON c.id = m.conversation_id
WHERE c.account_id IS NOT NULL
  AND btrim(COALESCE(a.path, '')) <> ''
  AND COALESCE(a.is_deleted, false) = false
ON CONFLICT DO NOTHING;

-- Record legacy rows that could not be represented uniquely. They remain
-- denied by the Functions until ownership can be resolved explicitly.
INSERT INTO public.chat_attachment_quarantine(
  file_id,
  bucket_id,
  file_name,
  reason_code,
  details
)
SELECT
  CASE
    WHEN a.path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    THEN a.path::uuid
    ELSE NULL
  END,
  CASE
    WHEN a.bucket IN ('chat-images', 'chat-attachments') THEN a.bucket
    ELSE 'chat-images'
  END,
  btrim(a.path),
  'legacy_ownership_conflict',
  jsonb_build_object(
    'attachment_id', a.id,
    'message_id', a.message_id
  )
FROM public.chat_attachments a
JOIN public.chat_messages m ON m.id = a.message_id
JOIN public.chat_conversations c ON c.id = m.conversation_id
WHERE c.account_id IS NOT NULL
  AND btrim(COALESCE(a.path, '')) <> ''
  AND COALESCE(a.is_deleted, false) = false
  AND NOT EXISTS (
    SELECT 1
    FROM public.chat_attachment_file_ownership o
    WHERE o.message_id = a.message_id
      AND o.bucket_id = CASE
        WHEN a.bucket IN ('chat-images', 'chat-attachments') THEN a.bucket
        ELSE 'chat-images'
      END
      AND o.file_name = btrim(a.path)
  )
ON CONFLICT DO NOTHING;

COMMIT;