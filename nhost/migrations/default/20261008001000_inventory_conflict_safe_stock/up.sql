BEGIN;

-- Validation has no side effects. PostgreSQL may execute BEFORE INSERT and
-- BEFORE UPDATE for one ON CONFLICT command; stock moves only after the row
-- transition which actually commits. Existing stock/history is not rewritten.
CREATE OR REPLACE FUNCTION public.enforce_inventory_ledger_stock()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE
  was_deleted boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'inventory_ledger_hard_delete_forbidden' USING ERRCODE = '23514';
  END IF;
  IF NEW.account_id IS NULL THEN
    RAISE EXCEPTION 'inventory_ledger_payload_invalid' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.account_id IS DISTINCT FROM NEW.account_id
       OR OLD.item_id IS DISTINCT FROM NEW.item_id THEN
      RAISE EXCEPTION 'inventory_ledger_entry_is_immutable' USING ERRCODE = '23514';
    END IF;
    was_deleted := COALESCE(OLD.is_deleted, false);
    IF was_deleted AND NOT COALESCE(NEW.is_deleted, false) THEN
      RAISE EXCEPTION 'inventory_ledger_reactivation_forbidden' USING ERRCODE = '23514';
    END IF;
    IF NOT was_deleted AND COALESCE(NEW.is_deleted, false) THEN
      NEW.reversed_at := COALESCE(OLD.reversed_at, now());
    END IF;
  END IF;

  -- Financial expenses without an inventory item remain supported.
  IF TG_TABLE_NAME = 'consumptions' AND NEW.item_id IS NULL THEN
    IF NEW.amount IS NOT NULL THEN
      NEW.amount_minor := round(NEW.amount * 100)::bigint;
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.item_id IS NULL OR NEW.quantity IS NULL OR NEW.quantity <= 0 THEN
    RAISE EXCEPTION 'inventory_ledger_payload_invalid' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.quantity IS DISTINCT FROM NEW.quantity THEN
      RAISE EXCEPTION 'inventory_ledger_entry_is_immutable' USING ERRCODE = '23514';
    END IF;
    IF TG_TABLE_NAME = 'consumptions' THEN
      IF OLD.amount IS DISTINCT FROM NEW.amount THEN
        RAISE EXCEPTION 'inventory_ledger_entry_is_immutable' USING ERRCODE = '23514';
      END IF;
    ELSE
      IF OLD.total IS DISTINCT FROM NEW.total THEN
        RAISE EXCEPTION 'inventory_ledger_entry_is_immutable' USING ERRCODE = '23514';
      END IF;
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'consumptions' THEN
    IF NEW.amount IS NOT NULL THEN
      NEW.amount_minor := round(NEW.amount * 100)::bigint;
      NEW.unit_price_snapshot := NEW.amount / NEW.quantity;
      NEW.unit_price_minor := round(NEW.unit_price_snapshot * 100)::bigint;
    END IF;
  ELSE
    IF NEW.total IS NOT NULL THEN
      NEW.amount_minor := round(NEW.total * 100)::bigint;
      NEW.unit_price_snapshot := NEW.total / NEW.quantity;
      NEW.unit_price_minor := round(NEW.unit_price_snapshot * 100)::bigint;
    END IF;
  END IF;
  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION public.apply_inventory_ledger_stock()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $function$
DECLARE
  old_effect numeric := 0;
  new_effect numeric := 0;
  delta numeric;
  affected integer;
BEGIN
  IF NEW.item_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND NOT COALESCE(OLD.is_deleted, false) THEN
    old_effect := OLD.quantity;
  END IF;
  IF NOT COALESCE(NEW.is_deleted, false) THEN new_effect := NEW.quantity; END IF;
  delta := new_effect - old_effect;
  IF TG_TABLE_NAME = 'consumptions' THEN delta := -delta; END IF;
  IF delta = 0 THEN RETURN NEW; END IF;
  -- One guarded UPDATE takes the item row lock, so concurrent consumptions and
  -- reversals cannot oversell; rejection rolls back the ledger row as well.
  UPDATE public.items SET stock = stock + delta, updated_at = now()
    WHERE account_id = NEW.account_id AND id = NEW.item_id
      AND stock + delta >= 0;
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 1 THEN
    RAISE EXCEPTION 'inventory_stock_update_rejected' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS consumptions_inventory_ledger_stock ON public.consumptions;
DROP TRIGGER IF EXISTS purchases_inventory_ledger_stock ON public.purchases;
CREATE TRIGGER consumptions_inventory_ledger_stock BEFORE INSERT OR UPDATE OR DELETE
  ON public.consumptions FOR EACH ROW EXECUTE FUNCTION public.enforce_inventory_ledger_stock();
CREATE TRIGGER purchases_inventory_ledger_stock BEFORE INSERT OR UPDATE OR DELETE
  ON public.purchases FOR EACH ROW EXECUTE FUNCTION public.enforce_inventory_ledger_stock();
DROP TRIGGER IF EXISTS consumptions_inventory_stock_delta ON public.consumptions;
DROP TRIGGER IF EXISTS purchases_inventory_stock_delta ON public.purchases;
CREATE TRIGGER consumptions_inventory_stock_delta AFTER INSERT OR UPDATE
  ON public.consumptions FOR EACH ROW EXECUTE FUNCTION public.apply_inventory_ledger_stock();
CREATE TRIGGER purchases_inventory_stock_delta AFTER INSERT OR UPDATE
  ON public.purchases FOR EACH ROW EXECUTE FUNCTION public.apply_inventory_ledger_stock();

COMMIT;
