-- Revert to previous return signatures (TABLE/jsonb/void) and drop views.

DROP FUNCTION IF EXISTS public.chat_mark_delivered(uuid[]);
DROP FUNCTION IF EXISTS public.chat_decline_invitation(uuid, text);
DROP FUNCTION IF EXISTS public.chat_accept_invitation(uuid);
DROP FUNCTION IF EXISTS public.delete_employee(uuid, uuid);
DROP FUNCTION IF EXISTS public.set_employee_disabled(uuid, uuid, boolean);
DROP FUNCTION IF EXISTS public.admin_create_employee_full(uuid, text, text);
DROP FUNCTION IF EXISTS public.admin_create_owner_full(text, text, text);
DROP FUNCTION IF EXISTS public.admin_delete_clinic(uuid);
DROP FUNCTION IF EXISTS public.admin_set_clinic_frozen(uuid, boolean);
DROP FUNCTION IF EXISTS public.list_employees_with_email(uuid);
DROP FUNCTION IF EXISTS public.admin_list_clinics();
DROP FUNCTION IF EXISTS public.my_feature_permissions(uuid);
DROP FUNCTION IF EXISTS public.my_profile();
DROP FUNCTION IF EXISTS public.my_account_id();

DROP VIEW IF EXISTS public.v_rpc_result;
DROP VIEW IF EXISTS public.v_list_employees_with_email;
DROP VIEW IF EXISTS public.v_admin_list_clinics;
DROP VIEW IF EXISTS public.v_my_feature_permissions;
DROP VIEW IF EXISTS public.v_my_profile;
DROP VIEW IF EXISTS public.v_my_account_id;

-- Restorations rely on previous migrations.
