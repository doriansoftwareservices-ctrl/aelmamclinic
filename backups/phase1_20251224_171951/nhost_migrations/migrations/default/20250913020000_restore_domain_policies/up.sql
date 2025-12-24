-- 20250913020000_restore_domain_policies.sql
-- Reinstates row-level security for business tables using fn_is_account_member.

CREATE OR REPLACE FUNCTION public.fn_is_account_member(p_account uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = p_account
      AND au.user_uid::text = public.request_uid_text()::uuid::text
      AND coalesce(au.disabled, false) = false
  );
$$;

REVOKE ALL ON FUNCTION public.fn_is_account_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_account_member(uuid) TO PUBLIC;

DO $$
DECLARE
  tbl text;
  managed_tables constant text[] := ARRAY[
    'patients','returns','consumptions','drugs','prescriptions','prescription_items',
    'complaints','appointments','doctors','consumption_types','medical_services',
    'service_doctor_share','employees','employees_loans','employees_salaries',
    'employees_discounts','item_types','items','purchases','alert_settings',
    'financial_logs','patient_services'
  ];
BEGIN
  FOR tbl IN SELECT unnest(managed_tables) LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);

    EXECUTE format('DROP POLICY IF EXISTS %I_select_member_or_super ON public.%I', tbl, tbl);
    EXECUTE format(
      'CREATE POLICY %I_select_member_or_super ON public.%I FOR SELECT TO PUBLIC USING (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id))',
      tbl, tbl, tbl
    );

    EXECUTE format('DROP POLICY IF EXISTS %I_insert_member_or_super ON public.%I', tbl, tbl);
    EXECUTE format(
      'CREATE POLICY %I_insert_member_or_super ON public.%I FOR INSERT TO PUBLIC WITH CHECK (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id))',
      tbl, tbl, tbl
    );

    EXECUTE format('DROP POLICY IF EXISTS %I_update_member_or_super ON public.%I', tbl, tbl);
    EXECUTE format(
      'CREATE POLICY %I_update_member_or_super ON public.%I FOR UPDATE TO PUBLIC USING (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id)) WITH CHECK (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id))',
      tbl, tbl, tbl, tbl
    );

    EXECUTE format('DROP POLICY IF EXISTS %I_delete_member_or_super ON public.%I', tbl, tbl);
    EXECUTE format(
      'CREATE POLICY %I_delete_member_or_super ON public.%I FOR DELETE TO PUBLIC USING (fn_is_super_admin() = true OR fn_is_account_member(%I.account_id))',
      tbl, tbl, tbl
    );
  END LOOP;
END $$;
