-- 20251025079800_drop_my_profile_for_patch.sql
-- Drops the existing my_profile signature so 20251025080000_patch.sql can redefine it.

DROP FUNCTION IF EXISTS public.my_profile();
