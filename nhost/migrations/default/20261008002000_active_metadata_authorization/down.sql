-- Preserve active-registry authorization and message identity protections.
DO $$ BEGIN RAISE EXCEPTION 'authorization_fix_requires_reviewed_forward_rollback'; END $$;
