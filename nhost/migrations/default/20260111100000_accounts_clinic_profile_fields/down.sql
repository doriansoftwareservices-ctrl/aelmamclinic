BEGIN;

-- 1) Drop the new signature
DROP FUNCTION IF EXISTS public.self_create_account(
  text, text, text, text, text, text, text, text, text
);

-- 2) Restore the old signature (single clinic name)
CREATE OR REPLACE FUNCTION public.self_create_account(
  p_clinic_name text
) RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid_text   text;
  v_uid        uuid;
  v_account_id uuid;
BEGIN
  v_uid_text := public.request_uid_text();

  IF v_uid_text IS NULL OR btrim(v_uid_text) = '' THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '28000';
  END IF;

  v_uid := v_uid_text::uuid;

  INSERT INTO public.accounts(
    id,
    name,
    created_at,
    updated_at
  )
  VALUES (
    gen_random_uuid(),
    btrim(coalesce(p_clinic_name, '')),
    now(),
    now()
  )
  RETURNING id INTO v_account_id;

  INSERT INTO public.account_users(
    account_id,
    user_uid,
    role,
    disabled,
    created_at,
    updated_at
  )
  VALUES (
    v_account_id,
    v_uid,
    'owner',
    false,
    now(),
    now()
  )
  ON CONFLICT (account_id, user_uid) DO UPDATE
    SET role = excluded.role,
        disabled = excluded.disabled,
        updated_at = now();

  -- Best-effort: set current account if RPC exists
  BEGIN
    IF EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname='public' AND p.proname='set_current_account'
    ) THEN
      PERFORM public.set_current_account(v_account_id);
    END IF;
  EXCEPTION WHEN others THEN
    -- ignore
  END;

  RETURN QUERY SELECT v_account_id::uuid AS id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.self_create_account(text) TO public;

-- 3) Remove added columns
ALTER TABLE public.accounts
  DROP COLUMN IF EXISTS clinic_name_en,
  DROP COLUMN IF EXISTS city_ar,
  DROP COLUMN IF EXISTS street_ar,
  DROP COLUMN IF EXISTS near_ar,
  DROP COLUMN IF EXISTS city_en,
  DROP COLUMN IF EXISTS street_en,
  DROP COLUMN IF EXISTS near_en,
  DROP COLUMN IF EXISTS phone;

COMMIT;
