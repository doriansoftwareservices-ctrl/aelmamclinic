-- Owned PostgreSQL14 schema-only fixture only. All mutations roll back.
BEGIN;
CREATE FUNCTION pg_temp.assert_pull_capability(expected text, reason text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE observed text; clock_value timestamptz; row_count integer;
BEGIN
  SELECT clinic_pull_clock_contract, server_now
    INTO observed, clock_value FROM public.app_server_now;
  SELECT count(*) INTO row_count FROM public.app_server_now;
  IF observed IS DISTINCT FROM expected OR clock_value IS NULL OR row_count <> 1 THEN
    RAISE EXCEPTION 'pull capability assertion failed: %', reason;
  END IF;
END;
$$;

SELECT pg_temp.assert_pull_capability('clinic_commit_clock_v1', 'complete installation');
DO $$
DECLARE domain_table text; checked integer := 0;
BEGIN
  FOR domain_table IN
    SELECT c.relname FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND t.tgname='zzzz_clinic_pull_clock'
    ORDER BY c.relname
  LOOP
    EXECUTE format('ALTER TABLE public.%I DISABLE TRIGGER zzzz_clinic_pull_clock', domain_table);
    PERFORM pg_temp.assert_pull_capability(NULL, 'disabled ' || domain_table);
    EXECUTE format('ALTER TABLE public.%I ENABLE TRIGGER zzzz_clinic_pull_clock', domain_table);
    PERFORM pg_temp.assert_pull_capability('clinic_commit_clock_v1', 'restored ' || domain_table);
    checked := checked + 1;
  END LOOP;
  IF checked <> 22 THEN RAISE EXCEPTION 'expected exactly22 fixture domains'; END IF;
END;
$$;

SAVEPOINT missing_trigger;
DROP TRIGGER zzzz_clinic_pull_clock ON public.items;
SELECT pg_temp.assert_pull_capability(NULL, 'missing writer trigger');
ROLLBACK TO SAVEPOINT missing_trigger;

SAVEPOINT filtered_trigger;
DROP TRIGGER zzzz_clinic_pull_clock ON public.items;
CREATE TRIGGER zzzz_clinic_pull_clock BEFORE INSERT OR UPDATE ON public.items
FOR EACH ROW WHEN (NEW.account_id IS NOT NULL)
EXECUTE FUNCTION public.tg_clinic_pull_clock();
SELECT pg_temp.assert_pull_capability(NULL, 'conditional writer trigger');
ROLLBACK TO SAVEPOINT filtered_trigger;

SAVEPOINT wrong_events;
DROP TRIGGER zzzz_clinic_pull_clock ON public.items;
CREATE TRIGGER zzzz_clinic_pull_clock BEFORE UPDATE OF name ON public.items
FOR EACH ROW EXECUTE FUNCTION public.tg_clinic_pull_clock();
SELECT pg_temp.assert_pull_capability(NULL, 'incomplete event and column coverage');
ROLLBACK TO SAVEPOINT wrong_events;

SAVEPOINT later_writer;
CREATE FUNCTION public.zzzzz_fixture_later_writer() RETURNS trigger LANGUAGE plpgsql
AS $$ BEGIN RETURN NEW; END; $$;
CREATE TRIGGER zzzzz_fixture_after_clock BEFORE UPDATE ON public.items
FOR EACH ROW EXECUTE FUNCTION public.zzzzz_fixture_later_writer();
SELECT pg_temp.assert_pull_capability(NULL, 'a later before-row writer');
ALTER TABLE public.items DISABLE TRIGGER zzzzz_fixture_after_clock;
SELECT pg_temp.assert_pull_capability('clinic_commit_clock_v1', 'disabled later trigger');
ROLLBACK TO SAVEPOINT later_writer;

SAVEPOINT function_drift;
CREATE OR REPLACE FUNCTION public.tg_clinic_pull_clock() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $$ BEGIN RETURN NEW; END; $$;
SELECT pg_temp.assert_pull_capability(NULL, 'writer body drift');
ROLLBACK TO SAVEPOINT function_drift;

SAVEPOINT function_scope;
ALTER FUNCTION public.tg_clinic_pull_clock() SET search_path=pg_catalog;
SELECT pg_temp.assert_pull_capability(NULL, 'writer search path drift');
ROLLBACK TO SAVEPOINT function_scope;

SAVEPOINT replica_mode;
SET LOCAL session_replication_role=replica;
SELECT pg_temp.assert_pull_capability(NULL, 'ordinary triggers do not run in replica mode');
ROLLBACK TO SAVEPOINT replica_mode;

SELECT pg_temp.assert_pull_capability('clinic_commit_clock_v1', 'all fixture mutations rolled back');
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_class c,
      LATERAL pg_catalog.aclexplode(COALESCE(c.relacl, pg_catalog.acldefault('r',c.relowner))) a
    WHERE c.oid='public.app_server_now'::regclass AND a.grantee=0
      AND a.privilege_type='SELECT'
  ) THEN RAISE EXCEPTION 'clock view must not have anonymous PUBLIC SELECT'; END IF;
END;
$$;
ROLLBACK;
