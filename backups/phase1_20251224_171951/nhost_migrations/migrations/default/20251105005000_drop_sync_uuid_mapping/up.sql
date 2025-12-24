-- 20251105005000_drop_sync_uuid_mapping.sql
-- Remove sync_uuid_mapping from the public schema; the mapping table is managed
-- locally in SQLite and should not live in Supabase (avoids RLS linter errors).

DROP TABLE IF EXISTS public.sync_uuid_mapping CASCADE;

