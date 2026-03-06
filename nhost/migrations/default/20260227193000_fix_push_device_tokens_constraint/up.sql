BEGIN;

-- Remove duplicate tokens (keep most recently updated)
WITH ranked AS (
  SELECT ctid,
         token,
         ROW_NUMBER() OVER (
           PARTITION BY token
           ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST
         ) AS rn
  FROM public.push_device_tokens
  WHERE token IS NOT NULL AND token <> ''
)
DELETE FROM public.push_device_tokens p
USING ranked r
WHERE p.ctid = r.ctid
  AND r.rn > 1;

DO $$
BEGIN
  -- If a standalone unique index exists with the same name, drop it so we can
  -- create a proper UNIQUE CONSTRAINT with that name.
  IF to_regclass('public.push_device_tokens_token_key') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM pg_constraint
       WHERE conname = 'push_device_tokens_token_key'
         AND conrelid = 'public.push_device_tokens'::regclass
     ) THEN
    DROP INDEX public.push_device_tokens_token_key;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'push_device_tokens_token_key'
      AND conrelid = 'public.push_device_tokens'::regclass
  ) THEN
    ALTER TABLE public.push_device_tokens
      ADD CONSTRAINT push_device_tokens_token_key UNIQUE (token);
  END IF;
END $$;

COMMIT;
