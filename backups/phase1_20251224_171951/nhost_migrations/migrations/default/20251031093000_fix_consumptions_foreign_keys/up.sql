-- 20251031093000_fix_consumptions_foreign_keys.sql
-- Cast legacy text foreign keys to uuid and wire proper constraints.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'consumptions'
      AND column_name = 'patient_id'
      AND data_type = 'text'
  ) THEN
    ALTER TABLE public.consumptions
      ADD COLUMN IF NOT EXISTS patient_id_uuid uuid,
      ADD COLUMN IF NOT EXISTS item_id_uuid uuid;

    UPDATE public.consumptions
    SET patient_id_uuid = CASE
          WHEN patient_id IS NULL OR btrim(patient_id) = '' THEN NULL
          WHEN patient_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN patient_id::uuid
          ELSE NULL
        END,
        item_id_uuid = CASE
          WHEN item_id IS NULL OR btrim(item_id) = '' THEN NULL
          WHEN item_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN item_id::uuid
          ELSE NULL
        END;

    ALTER TABLE public.consumptions
      DROP COLUMN patient_id,
      DROP COLUMN item_id;

    ALTER TABLE public.consumptions
      RENAME COLUMN patient_id_uuid TO patient_id;

    ALTER TABLE public.consumptions
      RENAME COLUMN item_id_uuid TO item_id;

    ALTER TABLE public.consumptions
      ADD CONSTRAINT consumptions_patient_id_fkey
        FOREIGN KEY (patient_id) REFERENCES public.patients(id)
        ON DELETE SET NULL;

    ALTER TABLE public.consumptions
      ADD CONSTRAINT consumptions_item_id_fkey
        FOREIGN KEY (item_id) REFERENCES public.items(id)
        ON DELETE SET NULL;
  END IF;
END;
$$;
