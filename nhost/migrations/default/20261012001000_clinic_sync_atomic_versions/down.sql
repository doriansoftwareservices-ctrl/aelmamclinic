BEGIN;
DROP FUNCTION IF EXISTS public.apply_clinic_sync_atomic(uuid,text,text,text,jsonb,jsonb,jsonb);
COMMIT;
