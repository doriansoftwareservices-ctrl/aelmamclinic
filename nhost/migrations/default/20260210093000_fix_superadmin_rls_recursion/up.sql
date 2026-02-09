BEGIN;

-- Disable RLS to avoid recursive policy/function calls on super_admins tables.
ALTER TABLE public.super_admins DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.super_admins NO FORCE ROW LEVEL SECURITY;

ALTER TABLE public.super_admin_tab_permissions DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.super_admin_tab_permissions NO FORCE ROW LEVEL SECURITY;

-- Drop policies that depend on fn_is_root_super_admin (which queries super_admins).
DROP POLICY IF EXISTS super_admins_select_root ON public.super_admins;
DROP POLICY IF EXISTS super_admins_select_self ON public.super_admins;

DROP POLICY IF EXISTS super_admin_tabs_select_self_or_root ON public.super_admin_tab_permissions;
DROP POLICY IF EXISTS super_admin_tabs_write_root ON public.super_admin_tab_permissions;
DROP POLICY IF EXISTS super_admin_tabs_update_root ON public.super_admin_tab_permissions;
DROP POLICY IF EXISTS super_admin_tabs_delete_root ON public.super_admin_tab_permissions;

COMMIT;
