BEGIN;

-- Round exact numeric first. Both signed bigint endpoints are legal; an input
-- with extra fractional precision is valid when its rounded amount fits.
-- This forward change does not rewrite any historical business or minor value.
CREATE OR REPLACE FUNCTION public.money_to_minor_or_null(p_value numeric)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $function$
DECLARE
  rounded_value numeric;
BEGIN
  IF lower(p_value::text) IN ('nan', 'infinity', '-infinity') THEN
    RETURN NULL;
  END IF;
  rounded_value := round(p_value * 100);
  IF rounded_value < -9223372036854775808
     OR rounded_value > 9223372036854775807 THEN
    RETURN NULL;
  END IF;
  RETURN rounded_value::bigint;
END;
$function$;

REVOKE ALL ON FUNCTION public.money_to_minor_or_null(numeric) FROM PUBLIC;

COMMIT;
