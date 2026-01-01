BEGIN;

-- Keep allow_all column but restore minimal view shape (without allow_all) if needed.
CREATE OR REPLACE VIEW public.v_my_feature_permissions AS
SELECT
  NULL::uuid AS account_id,
  ARRAY[]::text[] AS allowed_features,
  NULL::boolean AS can_create,
  NULL::boolean AS can_update,
  NULL::boolean AS can_delete
WHERE false;

COMMIT;
