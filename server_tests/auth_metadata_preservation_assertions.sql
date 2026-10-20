-- Private fixture captured by auth_metadata_preservation_snapshot.sql only.
DO $assertions$
DECLARE v_relation record; v_hash text;
BEGIN
  IF EXISTS(SELECT 1 FROM auth.users WHERE jsonb_typeof(metadata) IS DISTINCT FROM 'object') THEN
    RAISE EXCEPTION 'invalid_metadata_remains';
  END IF;
  IF EXISTS(SELECT 1 FROM elmam_auth_metadata_fixture.users_before b FULL JOIN auth.users u ON u.id=b.id
    WHERE b.id IS NULL OR u.id IS NULL OR b.identity IS DISTINCT FROM to_jsonb(u)-'metadata'-'updated_at') THEN
    RAISE EXCEPTION 'auth_identity_or_authority_changed';
  END IF;
  IF EXISTS(SELECT 1 FROM elmam_auth_metadata_fixture.users_before b JOIN auth.users u USING(id)
    WHERE jsonb_typeof(b.metadata)='object' AND b.metadata IS DISTINCT FROM u.metadata) THEN
    RAISE EXCEPTION 'valid_object_metadata_changed';
  END IF;
  IF EXISTS(SELECT 1 FROM elmam_auth_metadata_fixture.users_before b JOIN auth.users u USING(id)
    WHERE jsonb_typeof(b.metadata) NOT IN ('object','null') AND b.metadata IS DISTINCT FROM
      u.metadata->'_elmam_auth_metadata_recovery_20261020') THEN
    RAISE EXCEPTION 'original_invalid_metadata_not_preserved';
  END IF;
  IF EXISTS(SELECT 1 FROM elmam_auth_metadata_fixture.helper_before b JOIN pg_proc p USING(oid)
    WHERE b.proowner IS DISTINCT FROM p.proowner OR b.proacl IS DISTINCT FROM p.proacl OR
      b.prosecdef IS DISTINCT FROM p.prosecdef OR b.proconfig IS DISTINCT FROM p.proconfig) THEN
    RAISE EXCEPTION 'claims_owner_acl_or_security_changed';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM elmam_auth_metadata_fixture.helper_before b JOIN pg_proc p USING(oid)) THEN
    RAISE EXCEPTION 'claims_helper_oid_changed';
  END IF;
  FOR v_relation IN SELECT * FROM elmam_auth_metadata_fixture.rows_before LOOP
    EXECUTE format('SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' ORDER BY to_jsonb(t)::text),'''')) FROM %I.%I t',
      split_part(v_relation.table_name,'.',1),split_part(v_relation.table_name,'.',2)) INTO v_hash;
    IF v_hash IS DISTINCT FROM v_relation.fingerprint THEN
      RAISE EXCEPTION 'preserved_table_changed: %',v_relation.table_name;
    END IF;
  END LOOP;
END;
$assertions$;
SELECT 'PASS_ALL_PUBLIC_TABLES_AUTH_ROLES_TOKENS_IDENTITIES_METADATA_AND_HELPER_PRIVILEGES_PRESERVED';
