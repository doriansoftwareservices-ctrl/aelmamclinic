-- 20250921_publication_add_chat_reactions.sql
-- إضافة جدول التفاعلات إلى Publication الخاصة بـ Realtime

DO $$
BEGIN
  -- نتأكد أن الـ publication موجودة (Supabase ينشئ supabase_realtime افتراضيًا)
  IF EXISTS (
    SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
  ) THEN
    -- قد يفشل إذا كان الجدول مضافًا مسبقًا، لذا نحاصر بالاستثناء
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_reactions;
    EXCEPTION
      WHEN duplicate_object THEN
        -- موجود بالفعل؛ نتجاهل
        NULL;
    END;
  END IF;
END$$;
