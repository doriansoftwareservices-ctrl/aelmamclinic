BEGIN;

-- 1) Add clinic profile fields to accounts
ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS clinic_name_en text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS city_ar       text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS street_ar     text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS near_ar       text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS city_en       text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS street_en     text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS near_en       text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS phone         text NOT NULL DEFAULT '';

-- 2) Update self_create_account to accept full clinic profile
DROP FUNCTION IF EXISTS public.self_create_account(text);

CREATE OR REPLACE FUNCTION public.self_create_account(
  p_clinic_name     text,
  p_city_ar         text,
  p_street_ar       text,
  p_near_ar         text,
  p_clinic_name_en  text,
  p_city_en         text,
  p_street_en       text,
  p_near_en         text,
  p_phone           text
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
    clinic_name_en,
    city_ar,
    street_ar,
    near_ar,
    city_en,
    street_en,
    near_en,
    phone,
    created_at,
    updated_at
  )
  VALUES (
    gen_random_uuid(),
    btrim(coalesce(p_clinic_name, '')),
    btrim(coalesce(p_clinic_name_en, '')),
    btrim(coalesce(p_city_ar, '')),
    btrim(coalesce(p_street_ar, '')),
    btrim(coalesce(p_near_ar, '')),
    btrim(coalesce(p_city_en, '')),
    btrim(coalesce(p_street_en, '')),
    btrim(coalesce(p_near_en, '')),
    btrim(coalesce(p_phone, '')),
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

  -- Best-effort: keep profiles in sync (if profiles table/columns exist)
  BEGIN
    IF EXISTS (
      SELECT 1
      FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = 'profiles'
    ) THEN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema='public' AND table_name='profiles' AND column_name='account_id'
      ) THEN
        EXECUTE 'UPDATE public.profiles SET account_id = $1 WHERE id = $2'
        USING v_account_id, v_uid;
      END IF;

      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema='public' AND table_name='profiles' AND column_name='role'
      ) THEN
        EXECUTE 'UPDATE public.profiles SET role = $1 WHERE id = $2'
        USING 'owner', v_uid;
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    -- ignore
  END;

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

GRANT EXECUTE ON FUNCTION public.self_create_account(
  text, text, text, text, text, text, text, text, text
) TO public;

COMMIT;
