-- Retain exact clinical timestamps and the validated request contract.
-- Reversal requires an explicit forward migration; dropping this column loses data.
DO $guard$ BEGIN RAISE EXCEPTION 'clinic_temporal_contract_forward_only'; END; $guard$;
