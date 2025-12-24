DO $$
BEGIN
  -- في بيئة Nhost قد لا يوجد عمود public ولا دالة create_bucket بنفس التوقيع
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'chat-attachments') THEN
    RETURN;
  END IF;

  INSERT INTO storage.buckets (id)
  VALUES ('chat-attachments')
  ON CONFLICT (id) DO NOTHING;
END$$;
