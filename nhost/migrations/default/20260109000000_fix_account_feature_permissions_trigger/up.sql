BEGIN;

CREATE OR REPLACE FUNCTION public.trg_seed_account_feature_permissions()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_plan text;
BEGIN
  SELECT s.plan_code INTO v_plan
  FROM public.account_subscriptions s
  WHERE s.account_id = NEW.account_id
    AND s.status = 'active'
  ORDER BY s.created_at DESC
  LIMIT 1;

  IF v_plan IS NULL OR btrim(v_plan) = '' THEN
    v_plan := 'free';
  END IF;

  PERFORM public.apply_plan_permissions(NEW.account_id, v_plan);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS seed_account_feature_permissions ON public.account_users;
CREATE TRIGGER seed_account_feature_permissions
AFTER INSERT ON public.account_users
FOR EACH ROW
EXECUTE FUNCTION public.trg_seed_account_feature_permissions();

UPDATE public.account_feature_permissions
SET allow_all = false
WHERE allow_all IS DISTINCT FROM false;

DO $$
DECLARE
  r record;
BEGIN
  IF to_regclass('public.accounts') IS NULL THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT
      a.id AS account_id,
      COALESCE(
        (
          SELECT s.plan_code
          FROM public.account_subscriptions s
          WHERE s.account_id = a.id
            AND s.status = 'active'
          ORDER BY s.created_at DESC
          LIMIT 1
        ),
        'free'
      ) AS plan_code
    FROM public.accounts a
  LOOP
    PERFORM public.apply_plan_permissions(r.account_id, r.plan_code);
  END LOOP;
END;
$$;

COMMIT;
