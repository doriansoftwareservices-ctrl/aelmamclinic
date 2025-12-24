-- 20251027090500_enable_pg_trgm.sql
-- Ensure pg_trgm is available without requiring superuser privileges.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
    RAISE NOTICE 'pg_trgm already enabled';
  ELSE
    RAISE NOTICE 'pg_trgm not enabled. Enable it from Supabase Dashboard → Database → Extensions.';
  END IF;
END;
$$;
