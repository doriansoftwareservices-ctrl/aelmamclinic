DO $$ BEGIN RAISE EXCEPTION 'Forward-only clinical integrity migration: restore from a verified backup or deploy a compatible forward migration'; END $$;
