BEGIN;

DROP FUNCTION IF EXISTS public.admin_delete_super_admin(text);
DROP FUNCTION IF EXISTS public.admin_set_super_admin_disabled(text, boolean);
DROP FUNCTION IF EXISTS public.admin_set_super_admin_tabs(uuid, text[]);
DROP FUNCTION IF EXISTS public.admin_list_super_admin_accounts();
DROP FUNCTION IF EXISTS public.admin_get_super_admin_tabs();

DROP VIEW IF EXISTS public.v_super_admin_account;
DROP VIEW IF EXISTS public.v_super_admin_tabs;

DROP POLICY IF EXISTS super_admins_select_root ON public.super_admins;

DROP POLICY IF EXISTS super_admin_tabs_delete_root ON public.super_admin_tab_permissions;
DROP POLICY IF EXISTS super_admin_tabs_update_root ON public.super_admin_tab_permissions;
DROP POLICY IF EXISTS super_admin_tabs_write_root ON public.super_admin_tab_permissions;
DROP POLICY IF EXISTS super_admin_tabs_select_self_or_root ON public.super_admin_tab_permissions;

DROP TABLE IF EXISTS public.super_admin_tab_permissions;

DROP FUNCTION IF EXISTS public.fn_is_root_super_admin();

COMMIT;
