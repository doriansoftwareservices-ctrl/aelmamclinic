BEGIN;

REVOKE ALL ON FUNCTION public.update_clinic_profile(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) FROM PUBLIC;
DROP FUNCTION IF EXISTS public.update_clinic_profile(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
);

COMMIT;
