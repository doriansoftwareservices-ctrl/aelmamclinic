-- Forward-only integrity fix: reverting the defective trigger would corrupt stock.
DO $$ BEGIN RAISE EXCEPTION 'inventory_integrity_fix_requires_forward_rollback'; END $$;
