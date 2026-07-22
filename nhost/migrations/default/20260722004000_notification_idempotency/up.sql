BEGIN;

CREATE TABLE IF NOT EXISTS public.notification_event_deliveries (
  event_id text PRIMARY KEY,
  event_type text NOT NULL,
  status text NOT NULL DEFAULT 'processing',
  attempts integer NOT NULL DEFAULT 1,
  claim_token text,
  lease_until timestamptz,
  result_summary jsonb,
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT notification_event_delivery_status_check
    CHECK (status IN ('processing', 'completed', 'failed'))
);

CREATE OR REPLACE FUNCTION public.claim_notification_event(
  p_event_id text,
  p_event_type text,
  p_claim_token text
)
RETURNS SETOF public.notification_event_deliveries
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  INSERT INTO public.notification_event_deliveries (
    event_id, event_type, status, attempts, claim_token, lease_until, updated_at
  ) VALUES (
    p_event_id,
    p_event_type,
    'processing',
    1,
    p_claim_token,
    now() + interval '5 minutes',
    now()
  )
  ON CONFLICT (event_id) DO UPDATE
    SET status = 'processing',
        attempts = notification_event_deliveries.attempts + 1,
        claim_token = EXCLUDED.claim_token,
        lease_until = now() + interval '5 minutes',
        updated_at = now(),
        last_error_code = NULL
  WHERE notification_event_deliveries.status <> 'completed'
    AND notification_event_deliveries.event_type = EXCLUDED.event_type
    AND (
      notification_event_deliveries.lease_until IS NULL
      OR notification_event_deliveries.lease_until < now()
    )
  RETURNING *;
$function$;

REVOKE ALL ON FUNCTION public.claim_notification_event(text, text, text) FROM PUBLIC;

COMMIT;
