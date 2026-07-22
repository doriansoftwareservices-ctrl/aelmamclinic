BEGIN;

DROP TRIGGER IF EXISTS consumptions_inventory_ledger_stock
  ON public.consumptions;
DROP TRIGGER IF EXISTS purchases_inventory_ledger_stock
  ON public.purchases;
DROP FUNCTION IF EXISTS public.enforce_inventory_ledger_stock();

ALTER TABLE public.consumptions
  DROP CONSTRAINT IF EXISTS consumptions_patient_same_account_fk,
  DROP CONSTRAINT IF EXISTS consumptions_item_same_account_fk;

-- Expanded snapshot columns and reconciliation records are intentionally kept.
-- Dropping them would destroy audit evidence; rollback is operationally a
-- forward-fix that restores enforcement after correcting the trigger.

COMMIT;
