BEGIN;

-- Restore only the helper implementation. Keep repaired object metadata and
-- its original recovery values: reintroducing arrays would break active Auth.
DO $patch$
DECLARE
  v_definition text := pg_get_functiondef(
    'public.auth_set_user_claims(uuid,text,uuid)'::regprocedure);
  v_column text;
BEGIN
  FOREACH v_column IN ARRAY ARRAY[
    'metadata', 'app_metadata', 'raw_app_meta_data', 'raw_user_meta_data'
  ] LOOP
    v_definition := replace(v_definition,
      format('public.elmam_auth_metadata_object(%I)', v_column),
      format('COALESCE(%I, ''''{}''''::jsonb)', v_column));
  END LOOP;
  EXECUTE v_definition;
END;
$patch$;
DROP FUNCTION public.elmam_auth_metadata_object(jsonb);

COMMIT;
