BEGIN;
SET LOCAL lock_timeout = '5s';

-- Keep the existing clock column and its type. The additive capability names
-- the reviewed writer contract, not the client version or successful network
-- reachability. Do not advertise it for a partial or disabled installation.
CREATE OR REPLACE VIEW public.app_server_now AS
WITH domains(table_name) AS (
  VALUES ('item_types'), ('items'), ('drugs'), ('medical_services'),
    ('consumption_types'), ('employees'), ('doctors'), ('service_doctor_share'),
    ('patients'), ('patient_services'), ('returns'), ('appointments'),
    ('prescriptions'), ('prescription_items'), ('purchases'), ('consumptions'),
    ('alert_settings'), ('employees_loans'), ('employees_salaries'),
    ('employees_discounts'), ('complaints'), ('financial_logs')
), writer_contract AS (
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS p
    WHERE p.oid = pg_catalog.to_regprocedure('public.tg_clinic_pull_clock()')
      AND p.prosecdef
      AND p.prorettype = 'pg_catalog.trigger'::regtype
      AND 'search_path=pg_catalog, public' = ANY(p.proconfig)
      -- Drift detector for the exact body installed by migration01000.
      -- This is not a security boundary against a database administrator.
      AND pg_catalog.md5(p.prosrc) = '2b24e706ad038872bcbba932944882c3'
  ) AS ready
), trigger_contract AS (
  SELECT bool_and(EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger AS clock_trigger
    WHERE clock_trigger.tgrelid = pg_catalog.to_regclass('public.' || table_name)
      AND clock_trigger.tgname = 'zzzz_clinic_pull_clock'
      AND (clock_trigger.tgenabled = 'A' OR
        (clock_trigger.tgenabled = 'O' AND
          pg_catalog.current_setting('session_replication_role') <> 'replica'))
      AND clock_trigger.tgfoid = pg_catalog.to_regprocedure('public.tg_clinic_pull_clock()')
      -- BEFORE INSERT OR UPDATE, FOR EACH ROW, without a WHEN or column filter.
      AND clock_trigger.tgtype = 23
      AND clock_trigger.tgqual IS NULL
      AND clock_trigger.tgattr::text = ''
      AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger AS later_trigger
        WHERE later_trigger.tgrelid = clock_trigger.tgrelid
          AND NOT later_trigger.tgisinternal
          AND (later_trigger.tgenabled = 'A' OR
            (later_trigger.tgenabled = 'O' AND
              pg_catalog.current_setting('session_replication_role') <> 'replica'))
          AND (later_trigger.tgtype::integer & 3) = 3
          AND (later_trigger.tgtype::integer & 20) <> 0
          AND later_trigger.tgname > clock_trigger.tgname
      )
  )) AS ready FROM domains
)
SELECT pg_catalog.clock_timestamp() AS server_now,
  CASE WHEN writer_contract.ready AND trigger_contract.ready
    THEN 'clinic_commit_clock_v1'::text
    ELSE NULL::text
  END AS clinic_pull_clock_contract
FROM writer_contract CROSS JOIN trigger_contract;

REVOKE ALL ON public.app_server_now FROM PUBLIC;
COMMIT;
