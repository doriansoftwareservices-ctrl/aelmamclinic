-- Post-migration sanity checks for Nhost.
-- Run using:
--   psql "$NHOST_DB_URL" -f scripts/nhost_post_migration_checks.sql

DO $$
DECLARE
  t text;
  v bigint;
  f_result text;
BEGIN
  -- 0) Core auth/admin helpers should exist
  FOREACH t IN ARRAY ARRAY[
    'fn_is_super_admin()',
    'fn_is_super_admin_gql()',
    'admin_create_owner_full(text, text, text)',
    'admin_create_employee_full(uuid, text, text)',
    'admin_bootstrap_clinic_for_email(text, text, text)',
    'admin_attach_employee(uuid, uuid, text)',
    'my_account_plan()',
    'list_payment_methods()',
    'create_subscription_request(text, uuid, numeric, text)',
    'admin_approve_subscription_request(uuid, text)',
    'admin_set_account_plan(uuid, text, text)',
    'admin_payment_stats()',
    'apply_plan_permissions(uuid, text)',
    'self_create_account(text)',
    'my_account_id()',
    'my_profile()',
    'my_feature_permissions(uuid)',
    'list_employees_with_email(uuid)'
  ] LOOP
    IF to_regprocedure('public.' || t) IS NULL THEN
      RAISE NOTICE 'Missing function: public.%', t;
    END IF;
  END LOOP;

  -- 0.1) request_uid_text should return text (not uuid)
  SELECT pg_get_function_result('public.request_uid_text()'::regprocedure)
    INTO f_result;
  IF f_result IS DISTINCT FROM 'text' THEN
    RAISE NOTICE 'request_uid_text() return type is %, expected text', f_result;
  END IF;

  -- 0.2) fn_is_super_admin_gql should return is_super_admin (view-backed)
  IF to_regclass('public.v_is_super_admin') IS NULL THEN
    RAISE NOTICE 'Missing view public.v_is_super_admin (fn_is_super_admin_gql expects it).';
  ELSE
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'v_is_super_admin'
        AND column_name = 'is_super_admin'
    ) THEN
      RAISE NOTICE 'v_is_super_admin has no is_super_admin column.';
    END IF;
  END IF;

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

-- Billing sanity
SELECT count(*) AS plans_count
FROM public.subscription_plans;

SELECT count(*) AS plan_features_count
FROM public.plan_features;

SELECT count(*) AS payment_methods_count
FROM public.payment_methods;

SELECT count(*) AS pending_subscription_requests
FROM public.subscription_requests
WHERE status = 'pending';

SELECT count(*) AS payment_stats_by_plan_rows
FROM public.admin_payment_stats_by_plan();

SELECT count(*) AS payment_stats_by_month_rows
FROM public.admin_payment_stats_by_month();

SELECT count(*) AS payment_stats_by_day_rows
FROM public.admin_payment_stats_by_day();

SELECT account_id, count(*) AS pending_requests_per_account
FROM public.subscription_requests
WHERE status = 'pending'
GROUP BY account_id
HAVING count(*) > 1;

SELECT count(*) AS account_users_invalid_role
FROM public.account_users
WHERE lower(coalesce(role, '')) NOT IN ('owner','admin','employee','superadmin');

SELECT count(*) AS ownerless_accounts
FROM public.accounts a
WHERE NOT EXISTS (
  SELECT 1 FROM public.account_users au
  WHERE au.account_id = a.id
    AND lower(coalesce(au.role, '')) = 'owner'
    AND coalesce(au.disabled, false) = false
);

SELECT count(*) AS employees_on_free_plan
FROM public.account_users au
JOIN public.account_subscriptions s
  ON s.account_id = au.account_id
WHERE lower(coalesce(au.role, '')) <> 'owner'
  AND s.status = 'active'
  AND lower(coalesce(s.plan_code, 'free')) = 'free';

-- 6) Super-admin sanity
SELECT count(*) AS super_admin_rows
FROM public.super_admins;

SELECT count(*) AS super_admins_missing_identity
FROM public.super_admins
WHERE (user_uid IS NULL) AND (email IS NULL OR btrim(email) = '');

-- 5) Check clinics view (should be non-empty if accounts exist)
SELECT count(*) AS clinics_view_count
FROM public.clinics;
