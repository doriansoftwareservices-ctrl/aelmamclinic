BEGIN;
-- An authenticated clock endpoint contains no clinic or user data. A client
-- may anchor offline access only to this explicit-offset database timestamp.
CREATE OR REPLACE VIEW public.app_server_now AS
SELECT clock_timestamp() AS server_now;
REVOKE ALL ON public.app_server_now FROM PUBLIC;
COMMIT;
