DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
    RAISE NOTICE 'pg_trgm already enabled';
  ELSE
    RAISE NOTICE 'pg_trgm not enabled. Enable it manually from Supabase Dashboard → Database → Extensions.';
  END IF;
END;
$$;
