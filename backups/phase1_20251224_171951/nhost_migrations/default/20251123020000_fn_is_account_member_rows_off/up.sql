-- 20251123020000_fn_is_account_member_rows_off.sql
-- Ensures fn_is_account_member bypasses account_users RLS entirely to prevent
-- stack-depth recursion when policies call the helper.

CREATE OR REPLACE FUNCTION public.fn_is_account_member(p_account uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result boolean := false;
  elevated boolean := false;
BEGIN
  IF p_account IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    EXECUTE 'set local role postgres';
    EXECUTE 'set local row_security = off';
    elevated := true;

    SELECT EXISTS (
      SELECT 1
        FROM public.account_users au
       WHERE au.account_id = p_account
         AND au.user_uid::text = public.request_uid_text()::text
         AND COALESCE(au.disabled, false) = false
    )
    INTO result;
  EXCEPTION
    WHEN OTHERS THEN
      IF elevated THEN
        BEGIN
          EXECUTE 'reset role';
        EXCEPTION
          WHEN OTHERS THEN NULL;
        END;
        elevated := false;
      END IF;
      RAISE;
  END;

  IF elevated THEN
    BEGIN
      EXECUTE 'reset role';
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
  END IF;

  RETURN COALESCE(result, false);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_is_account_member(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_is_account_member(uuid) TO PUBLIC;
