BEGIN;

-- Best-effort rollback for chat codes
DROP FUNCTION IF EXISTS public.owner_create_employee_within_limit(json, text, text);
DROP FUNCTION IF EXISTS public.admin_dashboard_account_members(json, uuid, boolean);
DROP VIEW IF EXISTS public.v_admin_dashboard_account_members;
DROP FUNCTION IF EXISTS public.chat_resolve_user_for_dm(json, text);
DROP VIEW IF EXISTS public.v_chat_user_lookup;
DROP FUNCTION IF EXISTS public.ensure_account_user_chat_code(uuid, uuid);
DROP FUNCTION IF EXISTS public.ensure_account_owner_chat_code(uuid);
DROP FUNCTION IF EXISTS public.generate_chat_code(text);

-- Restore v_my_profile/v_list_employees_with_email to previous shape (without chat_code)
CREATE OR REPLACE VIEW public.v_my_profile AS
SELECT
  NULL::uuid AS id,
  NULL::text AS email,
  NULL::text AS role,
  NULL::uuid AS account_id,
  NULL::text AS display_name,
  ARRAY[]::uuid[] AS account_ids
WHERE false;

CREATE OR REPLACE VIEW public.v_list_employees_with_email AS
SELECT
  NULL::uuid AS user_uid,
  NULL::text AS email,
  NULL::text AS role,
  NULL::boolean AS disabled,
  NULL::timestamptz AS created_at,
  NULL::uuid AS employee_id,
  NULL::uuid AS doctor_id
WHERE false;

ALTER TABLE public.account_users
  DROP CONSTRAINT IF EXISTS account_users_chat_code_format;

DROP INDEX IF EXISTS account_users_chat_code_key;

ALTER TABLE public.account_users
  DROP COLUMN IF EXISTS chat_code;

COMMIT;
