-- Create storage bucket for subscription payment proofs

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'subscription-proofs') THEN
    RETURN;
  END IF;

  INSERT INTO storage.buckets (id)
  VALUES ('subscription-proofs')
  ON CONFLICT (id) DO NOTHING;
END$$;
