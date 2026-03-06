BEGIN;

ALTER TABLE public.push_device_tokens
  DROP CONSTRAINT IF EXISTS push_device_tokens_token_key;

COMMIT;
