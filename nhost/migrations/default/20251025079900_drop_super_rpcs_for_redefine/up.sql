-- 20251025079900_drop_super_rpcs_for_redefine.sql
-- Drops legacy definitions so 20251025080000_patch.sql can redefine them with new OUT columns.

DROP FUNCTION IF EXISTS public.admin_list_clinics();
DROP FUNCTION IF EXISTS public.my_feature_permissions(uuid);
