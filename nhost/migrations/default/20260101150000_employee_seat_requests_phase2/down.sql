BEGIN;

DROP FUNCTION IF EXISTS public.owner_submit_employee_seat_payment(json, uuid, uuid, text);
DROP FUNCTION IF EXISTS public.owner_request_extra_employee(json, text, text);
DROP FUNCTION IF EXISTS public.owner_create_employee_within_limit(json, text, text);

DROP TRIGGER IF EXISTS employee_seat_requests_set_updated_at
  ON public.employee_seat_requests;

DROP TABLE IF EXISTS public.employee_seat_requests;

COMMIT;
