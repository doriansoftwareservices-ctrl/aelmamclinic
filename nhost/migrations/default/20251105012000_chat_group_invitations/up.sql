-- Fixed migration: chat_group_invitations (no aliases in policies/indexes)

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1) Enum للحالات (مرة واحدة فقط)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'chat_invitation_status'
  ) THEN
    CREATE TYPE public.chat_invitation_status AS ENUM ('pending','accepted','declined','expired');
  END IF;
END $$;

-- 2) الجدول
CREATE TABLE IF NOT EXISTS public.chat_group_invitations (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  inviter        uuid NOT NULL,          -- auth.users.id (لا نضع FK لتجنب تعارضات صلاحيات)
  invitee_email  text NOT NULL,
  invitee_user   uuid NULL,              -- auth.users.id (اختياري)
  status         public.chat_invitation_status NOT NULL DEFAULT 'pending',
  response_note  text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  responded_at   timestamptz NULL,
  updated_at     timestamptz NULL
);

-- 3) قيود وفهارس
ALTER TABLE public.chat_group_invitations
  DROP CONSTRAINT IF EXISTS chat_group_invitations_email_chk,
  ADD  CONSTRAINT chat_group_invitations_email_chk
       CHECK (position('@' in invitee_email) > 1);

CREATE INDEX IF NOT EXISTS idx_cgi_conversation  ON public.chat_group_invitations(conversation_id);
CREATE INDEX IF NOT EXISTS idx_cgi_invitee_email ON public.chat_group_invitations((lower(invitee_email)));
CREATE INDEX IF NOT EXISTS idx_cgi_status        ON public.chat_group_invitations(status);
CREATE INDEX IF NOT EXISTS idx_cgi_responded     ON public.chat_group_invitations(responded_at);

-- 4) RLS
ALTER TABLE public.chat_group_invitations ENABLE ROW LEVEL SECURITY;

-- القراءة: الداعي، المدعو، أو أي مشارك في نفس المحادثة
CREATE POLICY chat_group_inv_select
  ON public.chat_group_invitations
  FOR SELECT
  USING (
    inviter = nullif(public.request_uid_text(), '')::uuid
    OR invitee_user = nullif(public.request_uid_text(), '')::uuid
    OR EXISTS (
      SELECT 1
      FROM public.chat_participants p
      WHERE p.conversation_id = chat_group_invitations.conversation_id
        AND p.user_uid = nullif(public.request_uid_text(), '')::uuid
    )
  );

-- الإدخال: فقط من مشارك في نفس المحادثة وباسمه كداعٍ
CREATE POLICY chat_group_inv_insert
  ON public.chat_group_invitations
  FOR INSERT
  WITH CHECK (
    inviter = nullif(public.request_uid_text(), '')::uuid
    AND EXISTS (
      SELECT 1
      FROM public.chat_participants p
      WHERE p.conversation_id = chat_group_invitations.conversation_id
        AND p.user_uid = nullif(public.request_uid_text(), '')::uuid
    )
  );

-- التعديل: الداعي أو المدعو
CREATE POLICY chat_group_inv_update
  ON public.chat_group_invitations
  FOR UPDATE
  USING (inviter = nullif(public.request_uid_text(), '')::uuid OR invitee_user = nullif(public.request_uid_text(), '')::uuid)
  WITH CHECK (inviter = nullif(public.request_uid_text(), '')::uuid OR invitee_user = nullif(public.request_uid_text(), '')::uuid);

-- الحذف: الداعي فقط
CREATE POLICY chat_group_inv_delete
  ON public.chat_group_invitations
  FOR DELETE
  USING (inviter = nullif(public.request_uid_text(), '')::uuid);

-- 5) Trigger updated_at
DROP TRIGGER IF EXISTS chat_group_invitations_set_updated_at ON public.chat_group_invitations;
CREATE TRIGGER chat_group_invitations_set_updated_at
BEFORE UPDATE ON public.chat_group_invitations
FOR EACH ROW
EXECUTE FUNCTION public.tg_set_updated_at();
