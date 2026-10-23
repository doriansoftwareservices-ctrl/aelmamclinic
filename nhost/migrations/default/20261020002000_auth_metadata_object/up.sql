BEGIN;

-- Auth 0.49.1 decodes user.metadata into a JSON object after rotating a token.
-- JSON null is not SQL NULL: COALESCE('null'::jsonb, '{}'::jsonb) || object
-- produces an array and makes /token fail after consuming its old token.
-- Keep every legacy value under a reserved recovery key; never infer authority
-- from it. Existing object metadata and all role/membership/plan rows stay intact.
CREATE OR REPLACE FUNCTION public.elmam_auth_metadata_object(p_value jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $function$
  SELECT CASE
    WHEN p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN '{}'::jsonb
    WHEN jsonb_typeof(p_value) = 'object' THEN p_value
    WHEN jsonb_typeof(p_value) = 'array' THEN
      coalesce((
        SELECT jsonb_object_agg(pair.key, pair.value ORDER BY element.ordinality)
        FROM jsonb_array_elements(p_value) WITH ORDINALITY AS element(value, ordinality)
        CROSS JOIN LATERAL jsonb_each(
          CASE WHEN jsonb_typeof(element.value) = 'object'
               THEN element.value ELSE '{}'::jsonb END
        ) AS pair
      ), '{}'::jsonb) ||
      jsonb_build_object('_elmam_auth_metadata_recovery_20261020', p_value)
    ELSE jsonb_build_object('_elmam_auth_metadata_recovery_20261020', p_value)
  END;
$function$;

-- Patch only the four JSON merge operands in the deployed helper. Replacing its
-- definition in place preserves OID, owner, ACL and the verified admin registry
-- checks. Abort on an unfamiliar helper instead of overwriting security policy.
DO $patch$
DECLARE
  v_definition text := pg_get_functiondef(
    'public.auth_set_user_claims(uuid,text,uuid)'::regprocedure);
  v_column text;
  v_old text;
  v_new text;
BEGIN
  IF position('superadmin_whitelist' IN v_definition) = 0 OR
     position('super_admin_tab_permissions' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Unexpected auth claims helper: registry checks missing';
  END IF;
  FOREACH v_column IN ARRAY ARRAY[
    'metadata', 'app_metadata', 'raw_app_meta_data', 'raw_user_meta_data'
  ] LOOP
    v_old := format('COALESCE(%I, ''''{}''''::jsonb)', v_column);
    v_new := format('public.elmam_auth_metadata_object(%I)', v_column);
    IF position(v_old IN v_definition) > 0 THEN
      v_definition := replace(v_definition, v_old, v_new);
    ELSIF position(v_new IN v_definition) = 0 THEN
      RAISE EXCEPTION 'Unexpected auth claims metadata operand: %', v_column;
    END IF;
  END LOOP;
  EXECUTE v_definition;
END;
$patch$;

UPDATE auth.users
SET metadata = public.elmam_auth_metadata_object(metadata)
WHERE jsonb_typeof(metadata) IS DISTINCT FROM 'object';

COMMIT;
