-- Authorization hardening is intentionally forward-only. Removing the private
-- marker could conflate administrative removal with a personal hide. A reviewed
-- forward migration is required to change this contract; retain all chat data.
DO $$ BEGIN RAISE NOTICE 'chat current authority retained; forward-only migration'; END $$;
