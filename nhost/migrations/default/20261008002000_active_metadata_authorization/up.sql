BEGIN;

CREATE OR REPLACE VIEW public.active_account_feature_access
WITH (security_barrier = true) AS
SELECT au.account_id, au.user_uid, afp.allow_all, afp.allowed_features,
       afp.can_create, afp.can_update, afp.can_delete
FROM public.account_users au
JOIN public.accounts a ON a.id = au.account_id
JOIN auth.users u ON u.id = au.user_uid
JOIN public.account_feature_permissions afp
  ON afp.account_id = au.account_id AND afp.user_uid = au.user_uid
WHERE au.disabled IS DISTINCT FROM true
  AND a.frozen IS DISTINCT FROM true AND u.disabled IS DISTINCT FROM true;

CREATE OR REPLACE VIEW public.active_superadmin_identity
WITH (security_barrier = true) AS
SELECT sa.user_uid FROM public.super_admins sa
JOIN auth.users u ON u.id = sa.user_uid
WHERE sa.disabled IS DISTINCT FROM true AND u.disabled IS DISTINCT FROM true;

CREATE OR REPLACE VIEW public.active_authenticated_identity
WITH (security_barrier = true) AS
SELECT id AS user_uid FROM auth.users WHERE disabled IS DISTINCT FROM true;

-- Message identity is immutable for every writer, including maintenance/admin.
-- Existing edit/delete/attachment commands remain available to active members.
CREATE OR REPLACE FUNCTION public.tg_chat_message_identity_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE
  actor uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF OLD.id IS DISTINCT FROM NEW.id
     OR OLD.conversation_id IS DISTINCT FROM NEW.conversation_id
     OR OLD.account_id IS DISTINCT FROM NEW.account_id
     OR OLD.sender_uid IS DISTINCT FROM NEW.sender_uid
     OR OLD.device_id IS DISTINCT FROM NEW.device_id
     OR OLD.local_id IS DISTINCT FROM NEW.local_id
     OR OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION 'chat_message_identity_is_immutable' USING ERRCODE = '42501';
  END IF;
  IF actor IS NOT NULL AND public.fn_is_super_admin() IS DISTINCT FROM true THEN
    IF NEW.sender_uid IS DISTINCT FROM actor OR NOT EXISTS (
      SELECT 1 FROM public.chat_participants p JOIN auth.users u ON u.id=p.user_uid
      WHERE p.conversation_id=NEW.conversation_id AND p.user_uid=actor
        AND p.is_deleted IS DISTINCT FROM true AND u.disabled IS DISTINCT FROM true
    ) THEN
      RAISE EXCEPTION 'chat_message_update_requires_active_membership' USING ERRCODE = '42501';
    END IF;
    IF NOT COALESCE(NEW.deleted, false)
       AND (NEW.body IS DISTINCT FROM OLD.body OR NEW.text IS DISTINCT FROM OLD.text
            OR NEW.attachments IS DISTINCT FROM OLD.attachments)
       AND NOT public.chat_can_send(NEW.conversation_id, actor) THEN
      RAISE EXCEPTION 'chat is locked' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END
$function$;
DROP TRIGGER IF EXISTS chat_message_identity_guard ON public.chat_messages;
CREATE TRIGGER chat_message_identity_guard BEFORE UPDATE ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public.tg_chat_message_identity_guard();

COMMIT;
