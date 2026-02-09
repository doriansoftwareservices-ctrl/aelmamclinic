BEGIN;

-- Re-enable RLS (policies are not recreated here).
ALTER TABLE public.super_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.super_admin_tab_permissions ENABLE ROW LEVEL SECURITY;

COMMIT;
