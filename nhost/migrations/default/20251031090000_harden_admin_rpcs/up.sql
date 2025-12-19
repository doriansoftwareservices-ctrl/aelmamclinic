-- 20251031090000_harden_admin_rpcs.sql (fixed)
DO $$
DECLARE
  fn_sig text;
  targets constant text[] := ARRAY[
    'public.admin_attach_employee(uuid, uuid, text)',
    'public.admin_bootstrap_clinic_for_email(text, text, text)',
    'public.delete_employee(uuid, uuid)',
    'public.fn_is_super_admin()'
  ];
BEGIN
  FOREACH fn_sig IN ARRAY targets LOOP
    IF to_regprocedure(fn_sig) IS NOT NULL THEN
      EXECUTE format('revoke all on function %s from public',        to_regprocedure(fn_sig));
      EXECUTE format('revoke all on function %s FROM PUBLIC',          to_regprocedure(fn_sig));
      EXECUTE format('grant execute on function %s TO public',to_regprocedure(fn_sig));
      EXECUTE format('grant execute on function %s TO public', to_regprocedure(fn_sig));
    ELSE
      RAISE NOTICE 'skip harden: function % not found', fn_sig;
    END IF;
  END LOOP;
END;
$$;
