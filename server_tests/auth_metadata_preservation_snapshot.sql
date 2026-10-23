-- Private restored PostgreSQL fixture only; never run against production.
CREATE SCHEMA elmam_auth_metadata_fixture;
CREATE TABLE elmam_auth_metadata_fixture.users_before AS
SELECT id, metadata, to_jsonb(u) - 'metadata' - 'updated_at' AS identity
FROM auth.users u;
CREATE TABLE elmam_auth_metadata_fixture.helper_before AS
SELECT oid, proowner, proacl, prosecdef, proconfig, pg_get_functiondef(oid) AS definition
FROM pg_proc WHERE oid = 'public.auth_set_user_claims(uuid,text,uuid)'::regprocedure;
CREATE TABLE elmam_auth_metadata_fixture.rows_before(table_name text PRIMARY KEY, fingerprint text);
DO $snapshot$
DECLARE v_relation record; v_hash text;
BEGIN
  FOR v_relation IN
    SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.relkind IN ('r','p') AND (n.nspname='public' OR
      n.nspname='auth' AND c.relname IN ('roles','user_roles','refresh_tokens'))
  LOOP
    EXECUTE format('SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E''\n'' ORDER BY to_jsonb(t)::text),'''')) FROM %I.%I t',
      v_relation.nspname,v_relation.relname) INTO v_hash;
    INSERT INTO elmam_auth_metadata_fixture.rows_before VALUES(
      v_relation.nspname||'.'||v_relation.relname,v_hash);
  END LOOP;
END;
$snapshot$;
