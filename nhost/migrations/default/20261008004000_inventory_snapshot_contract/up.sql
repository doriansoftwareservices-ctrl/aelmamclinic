BEGIN;

-- Match the existing model/function contract without fabricating old labels.
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS item_name_snapshot text;
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS item_type_name_snapshot text;

CREATE OR REPLACE FUNCTION public.capture_purchase_item_snapshot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE item_name text; type_name text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.item_name_snapshot IS DISTINCT FROM NEW.item_name_snapshot
       OR OLD.item_type_name_snapshot IS DISTINCT FROM NEW.item_type_name_snapshot THEN
      RAISE EXCEPTION 'inventory_ledger_snapshot_is_immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;
  SELECT i.name, t.name INTO item_name, type_name
  FROM public.items i
  LEFT JOIN public.item_types t ON t.id=i.type_id AND t.account_id=i.account_id
  WHERE i.id=NEW.item_id AND i.account_id=NEW.account_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inventory_ledger_item_account_mismatch' USING ERRCODE = '23514';
  END IF;
  -- Older clients omit these fields; new clients can preserve invoice labels.
  NEW.item_name_snapshot := COALESCE(NEW.item_name_snapshot, item_name);
  NEW.item_type_name_snapshot := COALESCE(NEW.item_type_name_snapshot, type_name);
  RETURN NEW;
END
$function$;
DROP TRIGGER IF EXISTS purchases_capture_item_snapshot ON public.purchases;
CREATE TRIGGER purchases_capture_item_snapshot BEFORE INSERT OR UPDATE
ON public.purchases FOR EACH ROW EXECUTE FUNCTION public.capture_purchase_item_snapshot();

COMMIT;
