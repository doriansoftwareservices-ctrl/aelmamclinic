-- Post-migration sanity checks for Nhost.
-- Run using:
--   psql "$NHOST_DB_URL" -f scripts/nhost_post_migration_checks.sql

DO $$
DECLARE
  t text;
  v bigint;
BEGIN
  -- 1) Ensure sync unique constraints exist
  FOREACH t IN ARRAY ARRAY[
    'patients_account_id_device_id_local_id_key',
    'returns_account_id_device_id_local_id_key',
    'consumptions_account_id_device_id_local_id_key',
    'drugs_account_id_device_id_local_id_key',
    'prescriptions_account_id_device_id_local_id_key',
    'prescription_items_account_id_device_id_local_id_key',
    'complaints_account_id_device_id_local_id_key',
    'appointments_account_id_device_id_local_id_key',
    'doctors_account_id_device_id_local_id_key',
    'consumption_types_account_id_device_id_local_id_key',
    'medical_services_account_id_device_id_local_id_key',
    'service_doctor_share_account_id_device_id_local_id_key',
    'employees_account_id_device_id_local_id_key',
    'employees_loans_account_id_device_id_local_id_key',
    'employees_salaries_account_id_device_id_local_id_key',
    'employees_discounts_account_id_device_id_local_id_key',
    'item_types_account_id_device_id_local_id_key',
    'items_account_id_device_id_local_id_key',
    'purchases_account_id_device_id_local_id_key',
    'alert_settings_account_id_device_id_local_id_key',
    'financial_logs_account_id_device_id_local_id_key',
    'patient_services_account_id_device_id_local_id_key'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint WHERE conname = t
    ) THEN
      RAISE NOTICE 'Missing unique constraint: %', t;
    END IF;
  END LOOP;

  -- 2) Check duplicate sync triplets (account_id, device_id, local_id)
  FOREACH t IN ARRAY ARRAY[
    'patients','returns','consumptions','drugs','prescriptions',
    'prescription_items','complaints','appointments','doctors',
    'consumption_types','medical_services','service_doctor_share',
    'employees','employees_loans','employees_salaries','employees_discounts',
    'item_types','items','purchases','alert_settings','financial_logs',
    'patient_services'
  ] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format(
        'SELECT count(*) FROM (SELECT account_id, device_id, local_id, count(*) AS c FROM public.%I GROUP BY 1,2,3 HAVING count(*) > 1) d',
        t
      ) INTO v;
      IF v > 0 THEN
        RAISE NOTICE 'Duplicates in %: % rows', t, v;
      END IF;

      EXECUTE format(
        'SELECT count(*) FROM public.%I WHERE account_id IS NULL OR device_id IS NULL OR local_id IS NULL',
        t
      ) INTO v;
      IF v > 0 THEN
        RAISE NOTICE 'Null sync columns in %: % rows', t, v;
      END IF;
    END IF;
  END LOOP;
END $$;

-- 3) Orphan checks for chat tables
SELECT count(*) AS orphan_messages
FROM public.chat_messages m
LEFT JOIN public.chat_conversations c ON c.id = m.conversation_id
WHERE c.id IS NULL;

SELECT count(*) AS orphan_participants
FROM public.chat_participants p
LEFT JOIN public.chat_conversations c ON c.id = p.conversation_id
WHERE c.id IS NULL;

SELECT count(*) AS orphan_reads
FROM public.chat_reads r
LEFT JOIN public.chat_conversations c ON c.id = r.conversation_id
WHERE c.id IS NULL;

SELECT count(*) AS orphan_attachments
FROM public.chat_attachments a
LEFT JOIN public.chat_messages m ON m.id = a.message_id
WHERE m.id IS NULL;

-- 4) Accounts / memberships sanity
SELECT count(*) AS accounts_missing_name
FROM public.accounts
WHERE name IS NULL OR btrim(name) = '';

SELECT count(*) AS account_users_missing_role
FROM public.account_users
WHERE role IS NULL OR btrim(role) = '';

-- 5) Check clinics view (should be non-empty if accounts exist)
SELECT count(*) AS clinics_view_count
FROM public.clinics;
