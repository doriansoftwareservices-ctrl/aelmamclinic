BEGIN;

-- Security forward-fix: do not restore the email-based membership RPCs and do
-- not discard invitation/audit evidence. Disable pending invitations instead.
UPDATE public.account_invitations
   SET status = 'revoked', revoked_at = coalesce(revoked_at, now())
 WHERE status = 'pending';

DROP FUNCTION IF EXISTS public.create_account_invitation_secure(
  uuid, text, text, uuid, timestamptz, boolean
);
DROP FUNCTION IF EXISTS public.accept_account_invitation_secure(text, uuid);
DROP FUNCTION IF EXISTS public.reject_account_invitation_secure(text, uuid);
DROP FUNCTION IF EXISTS public.revoke_account_invitation_secure(uuid, uuid);
DROP FUNCTION IF EXISTS public.account_employee_seat_limit(uuid);

COMMIT;
