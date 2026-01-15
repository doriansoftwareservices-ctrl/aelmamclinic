BEGIN;

CREATE OR REPLACE FUNCTION public.update_clinic_profile(
  p_clinic_name text,
  p_city_ar text,
  p_street_ar text,
  p_near_ar text,
  p_clinic_name_en text,
  p_city_en text,
  p_street_en text,
  p_near_en text,
  p_phone text
)
RETURNS TABLE(ok boolean, error text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
  v_account uuid;
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN QUERY SELECT false, 'unauthenticated';
    RETURN;
  END IF;

  IF p_clinic_name IS NULL OR btrim(p_clinic_name) = '' THEN
    RETURN QUERY SELECT false, 'clinic_name_required';
    RETURN;
  END IF;
  IF p_city_ar IS NULL OR btrim(p_city_ar) = '' THEN
    RETURN QUERY SELECT false, 'city_ar_required';
    RETURN;
  END IF;
  IF p_street_ar IS NULL OR btrim(p_street_ar) = '' THEN
    RETURN QUERY SELECT false, 'street_ar_required';
    RETURN;
  END IF;
  IF p_near_ar IS NULL OR btrim(p_near_ar) = '' THEN
    RETURN QUERY SELECT false, 'near_ar_required';
    RETURN;
  END IF;
  IF p_clinic_name_en IS NULL OR btrim(p_clinic_name_en) = '' THEN
    RETURN QUERY SELECT false, 'clinic_name_en_required';
    RETURN;
  END IF;
  IF p_city_en IS NULL OR btrim(p_city_en) = '' THEN
    RETURN QUERY SELECT false, 'city_en_required';
    RETURN;
  END IF;
  IF p_street_en IS NULL OR btrim(p_street_en) = '' THEN
    RETURN QUERY SELECT false, 'street_en_required';
    RETURN;
  END IF;
  IF p_near_en IS NULL OR btrim(p_near_en) = '' THEN
    RETURN QUERY SELECT false, 'near_en_required';
    RETURN;
  END IF;
  IF p_phone IS NULL OR btrim(p_phone) = '' THEN
    RETURN QUERY SELECT false, 'phone_required';
    RETURN;
  END IF;

  SELECT au.account_id, au.role
    INTO v_account, v_role
    FROM public.account_users au
   WHERE au.user_uid = v_uid
     AND coalesce(au.disabled, false) = false
   ORDER BY au.created_at DESC
   LIMIT 1;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT false, 'account_not_found';
    RETURN;
  END IF;

  IF public.fn_is_super_admin() IS NOT TRUE
     AND lower(coalesce(v_role, '')) NOT IN ('owner', 'admin') THEN
    RETURN QUERY SELECT false, 'forbidden';
    RETURN;
  END IF;

  UPDATE public.accounts
     SET name = p_clinic_name,
         clinic_name_en = p_clinic_name_en,
         city_ar = p_city_ar,
         street_ar = p_street_ar,
         near_ar = p_near_ar,
         city_en = p_city_en,
         street_en = p_street_en,
         near_en = p_near_en,
         phone = p_phone
   WHERE id = v_account;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'update_failed';
    RETURN;
  END IF;

  RETURN QUERY SELECT true, NULL::text;
END;
$$;

REVOKE ALL ON FUNCTION public.update_clinic_profile(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_clinic_profile(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) TO PUBLIC;

COMMIT;
