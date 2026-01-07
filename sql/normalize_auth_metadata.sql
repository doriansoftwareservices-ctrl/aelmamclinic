-- Normalize auth.users.metadata to a JSON object (defensive).
-- Safe to re-run.
UPDATE auth.users
SET metadata = COALESCE(
  CASE
    WHEN jsonb_typeof(metadata) = 'array' THEN metadata->1
    ELSE metadata
  END,
  '{}'::jsonb
)
WHERE metadata IS NOT NULL;
