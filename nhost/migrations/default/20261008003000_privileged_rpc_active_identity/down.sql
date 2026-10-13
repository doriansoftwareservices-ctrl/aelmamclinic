-- Do not restore claim/email-based privilege. Use a reviewed forward rollback.
DO $$ BEGIN RAISE EXCEPTION 'privileged_identity_requires_forward_rollback'; END $$;
