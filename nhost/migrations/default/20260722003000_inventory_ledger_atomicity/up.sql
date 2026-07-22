BEGIN;

ALTER TABLE public.items
  ALTER COLUMN stock SET DEFAULT 0;
UPDATE public.items SET stock = 0 WHERE stock IS NULL;
ALTER TABLE public.items
  ALTER COLUMN stock SET NOT NULL;

ALTER TABLE public.consumptions
  ADD COLUMN IF NOT EXISTS unit_price_snapshot numeric(20, 4),
  ADD COLUMN IF NOT EXISTS unit_price_minor bigint,
  ADD COLUMN IF NOT EXISTS amount_minor bigint,
  ADD COLUMN IF NOT EXISTS reversed_at timestamptz;

ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS unit_price_snapshot numeric(20, 4),
  ADD COLUMN IF NOT EXISTS unit_price_minor bigint,
  ADD COLUMN IF NOT EXISTS amount_minor bigint,
  ADD COLUMN IF NOT EXISTS reversed_at timestamptz;

UPDATE public.consumptions
   SET unit_price_snapshot = CASE
         WHEN quantity > 0 AND amount IS NOT NULL THEN amount / quantity
         ELSE unit_price_snapshot
       END,
       unit_price_minor = CASE
         WHEN quantity > 0 AND amount IS NOT NULL
           THEN round((amount / quantity) * 100)::bigint
         ELSE unit_price_minor
       END,
       amount_minor = CASE
         WHEN amount IS NOT NULL THEN round(amount * 100)::bigint
         ELSE amount_minor
       END
 WHERE unit_price_snapshot IS NULL
    OR unit_price_minor IS NULL
    OR amount_minor IS NULL;

UPDATE public.purchases
   SET unit_price_snapshot = CASE
         WHEN quantity > 0 AND total IS NOT NULL THEN total / quantity
         ELSE unit_price_snapshot
       END,
       unit_price_minor = CASE
         WHEN quantity > 0 AND total IS NOT NULL
           THEN round((total / quantity) * 100)::bigint
         ELSE unit_price_minor
       END,
       amount_minor = CASE
         WHEN total IS NOT NULL THEN round(total * 100)::bigint
         ELSE amount_minor
       END
 WHERE unit_price_snapshot IS NULL
    OR unit_price_minor IS NULL
    OR amount_minor IS NULL;

CREATE TABLE IF NOT EXISTS public.inventory_reconciliation_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  issue_code text NOT NULL,
  entity_table text NOT NULL,
  entity_id uuid,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'open',
  detected_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolved_by_user_id uuid,
  CONSTRAINT inventory_reconciliation_status_check
    CHECK (status IN ('open', 'reviewed', 'resolved', 'ignored'))
);

CREATE UNIQUE INDEX IF NOT EXISTS inventory_reconciliation_open_uix
  ON public.inventory_reconciliation_issues(
    account_id, issue_code, entity_table, entity_id
  )
  WHERE status = 'open';

INSERT INTO public.inventory_reconciliation_issues (
  account_id, issue_code, entity_table, entity_id, details
)
SELECT account_id, 'negative_stock_before_atomic_ledger', 'items', id,
       jsonb_build_object('stock', stock)
  FROM public.items
 WHERE stock < 0
ON CONFLICT DO NOTHING;

INSERT INTO public.inventory_reconciliation_issues (
  account_id, issue_code, entity_table, entity_id, details
)
SELECT account_id, 'consumption_snapshot_missing', 'consumptions', id,
       jsonb_build_object('quantity', quantity)
  FROM public.consumptions
 WHERE amount IS NULL OR unit_price_snapshot IS NULL
ON CONFLICT DO NOTHING;

ALTER TABLE public.consumptions
  DROP CONSTRAINT IF EXISTS consumptions_patient_same_account_fk,
  DROP CONSTRAINT IF EXISTS consumptions_item_same_account_fk;
ALTER TABLE public.consumptions
  ADD CONSTRAINT consumptions_patient_same_account_fk
    FOREIGN KEY (account_id, patient_id)
    REFERENCES public.patients(account_id, id) NOT VALID,
  ADD CONSTRAINT consumptions_item_same_account_fk
    FOREIGN KEY (account_id, item_id)
    REFERENCES public.items(account_id, id) NOT VALID;

CREATE OR REPLACE FUNCTION public.enforce_inventory_ledger_stock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  affected integer;
  was_deleted boolean;
  is_deleted_now boolean;
BEGIN
  IF NEW.account_id IS NULL OR NEW.item_id IS NULL OR NEW.quantity IS NULL
     OR NEW.quantity <= 0 THEN
    RAISE EXCEPTION 'inventory_ledger_payload_invalid'
      USING ERRCODE = '22023';
  END IF;

  is_deleted_now := COALESCE(NEW.is_deleted, false);

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

  IF TG_OP = 'INSERT' THEN
    IF is_deleted_now THEN
      RETURN NEW;
    END IF;

    IF TG_TABLE_NAME = 'consumptions' THEN
      UPDATE public.items
         SET stock = stock - NEW.quantity,
             updated_at = now()
       WHERE id = NEW.item_id
         AND account_id = NEW.account_id
         AND stock >= NEW.quantity;
    ELSE
      UPDATE public.items
         SET stock = stock + NEW.quantity,
             updated_at = now()
       WHERE id = NEW.item_id
         AND account_id = NEW.account_id;
    END IF;
    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 1 THEN
      RAISE EXCEPTION 'inventory_stock_update_rejected'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  was_deleted := COALESCE(OLD.is_deleted, false);
  IF OLD.account_id IS DISTINCT FROM NEW.account_id
     OR OLD.item_id IS DISTINCT FROM NEW.item_id
     OR OLD.quantity IS DISTINCT FROM NEW.quantity THEN
    RAISE EXCEPTION 'inventory_ledger_entry_is_immutable'
      USING ERRCODE = '23514';
  END IF;
  IF TG_TABLE_NAME = 'consumptions' THEN
    IF OLD.amount IS DISTINCT FROM NEW.amount THEN
      RAISE EXCEPTION 'inventory_ledger_entry_is_immutable'
        USING ERRCODE = '23514';
    END IF;
  ELSIF OLD.total IS DISTINCT FROM NEW.total THEN
    RAISE EXCEPTION 'inventory_ledger_entry_is_immutable'
      USING ERRCODE = '23514';
  END IF;

  IF was_deleted AND NOT is_deleted_now THEN
    RAISE EXCEPTION 'inventory_ledger_reactivation_forbidden'
      USING ERRCODE = '23514';
  END IF;

  IF NOT was_deleted AND is_deleted_now THEN
    NEW.reversed_at := COALESCE(NEW.reversed_at, now());
    IF TG_TABLE_NAME = 'consumptions' THEN
      UPDATE public.items
         SET stock = stock + OLD.quantity,
             updated_at = now()
       WHERE id = OLD.item_id
         AND account_id = OLD.account_id;
    ELSE
      UPDATE public.items
         SET stock = stock - OLD.quantity,
             updated_at = now()
       WHERE id = OLD.item_id
         AND account_id = OLD.account_id
         AND stock >= OLD.quantity;
    END IF;
    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 1 THEN
      RAISE EXCEPTION 'inventory_reversal_rejected'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS consumptions_inventory_ledger_stock
  ON public.consumptions;
CREATE TRIGGER consumptions_inventory_ledger_stock
BEFORE INSERT OR UPDATE ON public.consumptions
FOR EACH ROW EXECUTE FUNCTION public.enforce_inventory_ledger_stock();

DROP TRIGGER IF EXISTS purchases_inventory_ledger_stock
  ON public.purchases;
CREATE TRIGGER purchases_inventory_ledger_stock
BEFORE INSERT OR UPDATE ON public.purchases
FOR EACH ROW EXECUTE FUNCTION public.enforce_inventory_ledger_stock();

COMMIT;
