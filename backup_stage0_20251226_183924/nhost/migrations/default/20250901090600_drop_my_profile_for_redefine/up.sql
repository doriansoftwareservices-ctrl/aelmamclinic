-- 20250901090600_drop_my_profile_for_redefine.sql
-- Allows later migrations to redefine my_profile with a different OUT signature.

DROP FUNCTION IF EXISTS public.my_profile();
