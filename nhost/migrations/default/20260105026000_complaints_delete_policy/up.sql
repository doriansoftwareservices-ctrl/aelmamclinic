BEGIN;

-- Ensure DELETE is explicitly allowed for superadmins after removing legacy policies.
DROP POLICY IF EXISTS complaints_delete ON public.complaints;
CREATE POLICY complaints_delete
  ON public.complaints
  FOR DELETE TO PUBLIC
  USING (public.fn_is_super_admin() = true);

COMMIT;
