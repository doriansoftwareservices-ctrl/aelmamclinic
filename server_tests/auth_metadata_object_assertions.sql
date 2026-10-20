-- Disposable restored cluster only. Every synthetic change is rolled back.
BEGIN;
DO $tests$
DECLARE
  v_value jsonb;
  v_result jsonb;
  v_uid uuid := gen_random_uuid();
  v_before jsonb;
  v_after jsonb;
  v_cases jsonb[] := ARRAY[
    NULL::jsonb, 'null'::jsonb, '{}'::jsonb,
    '{"name":"عيادة","nested":{"x":[1,true,null]}}'::jsonb,
    '[null,{"role":"owner","account_id":"synthetic"}]'::jsonb,
    '[{"x":1},{"x":2,"y":3}]'::jsonb,
    '[[1],false,"text",null,{"kept":true}]'::jsonb,
    '"legacy"'::jsonb, '42'::jsonb, 'false'::jsonb
  ];
BEGIN
  FOREACH v_value IN ARRAY v_cases LOOP
    v_result := public.elmam_auth_metadata_object(v_value);
    IF jsonb_typeof(v_result) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'normalization_not_object';
    END IF;
    IF public.elmam_auth_metadata_object(v_result) IS DISTINCT FROM v_result THEN
      RAISE EXCEPTION 'normalization_not_idempotent';
    END IF;
    IF jsonb_typeof(v_value) = 'object' AND v_result IS DISTINCT FROM v_value THEN
      RAISE EXCEPTION 'existing_object_changed';
    END IF;
    IF jsonb_typeof(v_value) NOT IN ('object','null') AND
       v_result->'_elmam_auth_metadata_recovery_20261020' IS DISTINCT FROM v_value THEN
      RAISE EXCEPTION 'legacy_value_not_preserved';
    END IF;
  END LOOP;
  IF public.elmam_auth_metadata_object('[{"x":1},{"x":2,"y":3}]')->>'x' <> '2' THEN
    RAISE EXCEPTION 'last_legacy_object_not_retained';
  END IF;
  INSERT INTO auth.users(id,email,display_name,locale,metadata,disabled)
  VALUES(v_uid,'metadata-fixture@example.invalid','Synthetic','en','null'::jsonb,false);
  SELECT to_jsonb(u) - 'metadata' - 'updated_at' - 'default_role' INTO v_before
  FROM auth.users u WHERE id = v_uid;
  PERFORM public.auth_set_user_claims(v_uid,'owner',NULL);
  SELECT to_jsonb(u) - 'metadata' - 'updated_at' - 'default_role',metadata
    INTO v_after,v_result FROM auth.users u WHERE id = v_uid;
  IF v_before IS DISTINCT FROM v_after OR jsonb_typeof(v_result) <> 'object' OR
     v_result->>'role' <> 'owner' THEN RAISE EXCEPTION 'owner_claim_write_changed_identity'; END IF;
  UPDATE auth.users SET metadata='[{"kept":"مرحبا"},{"role":"employee"}]' WHERE id=v_uid;
  PERFORM public.auth_set_user_claims(v_uid,'employee',NULL);
  SELECT metadata INTO v_result FROM auth.users WHERE id=v_uid;
  IF v_result->>'kept' <> 'مرحبا' OR v_result->>'role' <> 'employee' OR
     v_result->'_elmam_auth_metadata_recovery_20261020' IS NULL THEN
    RAISE EXCEPTION 'employee_metadata_lost';
  END IF;
  PERFORM public.auth_set_user_claims(v_uid,'superadmin',NULL);
  IF EXISTS(SELECT 1 FROM auth.user_roles WHERE user_id=v_uid AND role='superadmin') OR
     (SELECT default_role FROM auth.users WHERE id=v_uid) <> 'user' THEN
    RAISE EXCEPTION 'unregistered_admin_escalated';
  END IF;
END;
$tests$;
SELECT 'PASS_METADATA_OBJECT_MATRIX_10_CASES_IDEMPOTENCE_PRESERVATION_OWNER_EMPLOYEE_ADMIN_GUARD';
ROLLBACK;
