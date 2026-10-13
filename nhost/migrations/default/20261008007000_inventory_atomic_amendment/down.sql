DO $$ BEGIN RAISE EXCEPTION 'Forward-only inventory history migration; restore compatible source or apply a corrective migration'; END $$;
