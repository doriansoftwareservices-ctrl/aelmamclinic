-- Revert to previous definition (same logic without hardened guard)
CREATE OR REPLACE FUNCTION public.chat_set_support_agent(
  p_user_uid uuid,
  p_display_name text DEFAULT 'خدمة العملاء'
)
RETURNS TABLE(user_uid uuid, display_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
SET row_security TO 'off'
AS $$
DECLARE
  v_uid uuid;
  v_name text;
BEGIN
  IF NOT public.fn_is_super_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_uid := p_user_uid;
  v_name := COALESCE(NULLIF(trim(p_display_name), ''), 'خدمة العملاء');

  UPDATE public.chat_support_agents
  SET is_active = false,
      updated_at = now()
  WHERE is_active = true;

  INSERT INTO public.chat_support_agents(
    user_uid,
    display_name,
    is_active,
    created_by,
    updated_at
  ) VALUES (
    v_uid,
    v_name,
    true,
    NULLIF(public.request_uid_text(), '')::uuid,
    now()
  )
  ON CONFLICT (user_uid)
  DO UPDATE SET
    display_name = EXCLUDED.display_name,
    is_active = true,
    updated_at = now();

  RETURN QUERY
  SELECT user_uid, display_name
  FROM public.chat_support_agents
  WHERE is_active = true
  ORDER BY updated_at DESC
  LIMIT 1;
END;
$$;
