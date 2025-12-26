-- 20250901090700_drop_my_feature_permissions_for_redefine.sql
-- Drops the early stub so core_domain_schema can redefine it with a different signature.

DROP FUNCTION IF EXISTS public.my_feature_permissions(uuid);
