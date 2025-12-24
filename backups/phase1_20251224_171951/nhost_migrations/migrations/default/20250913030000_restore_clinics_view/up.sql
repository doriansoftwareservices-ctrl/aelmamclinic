-- 20250913030000_restore_clinics_view.sql
-- Provides the clinics view consumed by admin inbox screens.

CREATE OR REPLACE VIEW public.clinics AS
SELECT
  id,
  name,
  frozen,
  created_at
FROM public.accounts;

-- وسياسات الـ RLS تُطبّق على الجدول الأساسي accounts، لذا نبقي العرض بدون هذا الخيار.

