BEGIN;

-- Restore placeholder view definition.
CREATE OR REPLACE VIEW public.v_my_account_id AS
SELECT NULL::uuid AS account_id
WHERE false;

-- Restore previous account membership helper (row security applies).
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
      AND au.user_uid::text = public.request_uid_text()::text
      AND coalesce(au.disabled, false) = false
  );
$$;

REVOKE ALL ON FUNCTION public.fn_is_account_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_account_member(uuid) TO PUBLIC;

COMMIT;
