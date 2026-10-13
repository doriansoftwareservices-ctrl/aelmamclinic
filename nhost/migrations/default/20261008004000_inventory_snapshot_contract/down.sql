-- Keep historical invoice labels and immutable-ledger protections.
DO $$ BEGIN RAISE EXCEPTION 'inventory_snapshot_requires_reviewed_forward_rollback'; END $$;
