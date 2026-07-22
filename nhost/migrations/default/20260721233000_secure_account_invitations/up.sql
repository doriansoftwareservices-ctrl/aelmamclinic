BEGIN;

CREATE TABLE IF NOT EXISTS public.account_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  email text NOT NULL,
  role text NOT NULL DEFAULT 'employee',
  token_hash text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending',
  invited_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  accepted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  expires_at timestamptz NOT NULL,
  accepted_at timestamptz,
  rejected_at timestamptz,
  revoked_at timestamptz,
  seat_request_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT account_invitations_email_normalized
    CHECK (email = lower(btrim(email)) AND position('@' IN email) > 1),
  CONSTRAINT account_invitations_role_check
    CHECK (role IN ('employee', 'admin')),
  CONSTRAINT account_invitations_status_check
    CHECK (status IN ('pending', 'accepted', 'rejected', 'expired', 'revoked')),
  CONSTRAINT account_invitations_token_hash_check
    CHECK (token_hash ~ '^[0-9a-f]{64}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS account_invitations_pending_account_email_uix
  ON public.account_invitations(account_id, email)
  WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS account_invitations_email_status_idx
  ON public.account_invitations(email, status, expires_at DESC);
CREATE INDEX IF NOT EXISTS account_invitations_account_created_idx
  ON public.account_invitations(account_id, created_at DESC);

ALTER TABLE public.employee_seat_requests
  ALTER COLUMN employee_user_uid DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS invitation_id uuid
    REFERENCES public.account_invitations(id) ON DELETE RESTRICT;

CREATE UNIQUE INDEX IF NOT EXISTS employee_seat_requests_invitation_uix
  ON public.employee_seat_requests(invitation_id)
  WHERE invitation_id IS NOT NULL;

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'account_invitations_seat_request_fk'
       AND conrelid = 'public.account_invitations'::regclass
  ) THEN
    ALTER TABLE public.account_invitations
      ADD CONSTRAINT account_invitations_seat_request_fk
      FOREIGN KEY (seat_request_id)
      REFERENCES public.employee_seat_requests(id)
      ON DELETE RESTRICT;
  END IF;
END
$do$;

DROP TRIGGER IF EXISTS account_invitations_set_updated_at
  ON public.account_invitations;
CREATE TRIGGER account_invitations_set_updated_at
BEFORE UPDATE ON public.account_invitations
FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at();

ALTER TABLE public.account_invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_invitations FROM PUBLIC;

CREATE TABLE IF NOT EXISTS public.account_membership_security_review (
  user_uid uuid NOT NULL,
  account_ids uuid[] NOT NULL,
  membership_count integer NOT NULL,
  reason_code text NOT NULL,
  discovered_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  review_note text,
  PRIMARY KEY (user_uid, reason_code)
);

INSERT INTO public.account_membership_security_review(
  user_uid, account_ids, membership_count, reason_code
)
SELECT au.user_uid,
       array_agg(au.account_id ORDER BY au.created_at),
       count(*)::integer,
       'multiple_account_memberships_pre_invitation'
  FROM public.account_users au
 WHERE coalesce(au.disabled, false) = false
 GROUP BY au.user_uid
HAVING count(*) > 1
ON CONFLICT (user_uid, reason_code) DO UPDATE
SET account_ids = excluded.account_ids,
    membership_count = excluded.membership_count;

CREATE OR REPLACE FUNCTION public.account_employee_seat_limit(p_account_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT CASE lower(coalesce((
    SELECT s.plan_code
      FROM public.account_subscriptions s
     WHERE s.account_id = p_account_id
       AND s.status = 'active'
       AND (s.end_at IS NULL OR s.end_at > now())
     ORDER BY s.updated_at DESC
     LIMIT 1
  ), 'free'))
    WHEN 'trial_month' THEN 5
    WHEN 'month' THEN 5
    WHEN 'year' THEN 5
    WHEN 'annual' THEN 5
    WHEN 'month_plus' THEN 10
    WHEN 'year_plus' THEN 10
    WHEN 'month_pro' THEN 20
    WHEN 'year_pro' THEN 20
    ELSE 0
  END;
$fn$;

CREATE OR REPLACE FUNCTION public.create_account_invitation_secure(
  p_account_id uuid,
  p_email text,
  p_token_hash text,
  p_invited_by uuid,
  p_expires_at timestamptz,
  p_extra_seat boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
SET row_security = off
AS $fn$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_invitation_id uuid;
  v_request_id uuid;
  v_target_uid uuid;
  v_limit integer;
  v_active_count integer;
  v_pending_count integer;
  v_price numeric := 0;
BEGIN
  IF p_account_id IS NULL OR p_invited_by IS NULL OR v_email = ''
     OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     OR p_token_hash !~ '^[0-9a-f]{64}$'
     OR p_expires_at <= now() OR p_expires_at > now() + interval '30 days' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_invitation');
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.account_users au
      JOIN public.accounts a ON a.id = au.account_id
      JOIN auth.users u ON u.id = au.user_uid
     WHERE au.account_id = p_account_id
       AND au.user_uid = p_invited_by
       AND lower(coalesce(au.role, '')) = 'owner'
       AND coalesce(au.disabled, false) = false
       AND coalesce(a.frozen, false) = false
       AND coalesce(u.disabled, false) = false
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;

  SELECT u.id INTO v_target_uid
    FROM auth.users u
   WHERE lower(u.email) = v_email
   LIMIT 1;

  IF v_target_uid = p_invited_by THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cannot_invite_self');
  END IF;
  IF v_target_uid IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.account_users au
     WHERE au.account_id = p_account_id
       AND au.user_uid = v_target_uid
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_already_member');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.account_invitations i
     WHERE i.account_id = p_account_id
       AND i.email = v_email
       AND i.status = 'pending'
       AND i.expires_at > now()
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_already_pending');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_account_id::text, 701));
  v_limit := public.account_employee_seat_limit(p_account_id);
  SELECT count(*)::integer INTO v_active_count
    FROM public.account_users au
   WHERE au.account_id = p_account_id
     AND lower(coalesce(au.role, '')) IN ('employee', 'admin')
     AND coalesce(au.disabled, false) = false;
  SELECT count(*)::integer INTO v_pending_count
    FROM public.account_invitations i
   WHERE i.account_id = p_account_id
     AND i.status = 'pending'
     AND i.expires_at > now()
     AND i.seat_request_id IS NULL;

  IF NOT p_extra_seat AND (v_limit = 0 OR v_active_count + v_pending_count >= v_limit) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'seat_limit_reached');
  END IF;
  IF p_extra_seat AND (v_limit = 0 OR v_active_count < v_limit) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'seat_limit_not_reached');
  END IF;

  UPDATE public.account_invitations
     SET status = 'expired'
   WHERE account_id = p_account_id
     AND email = v_email
     AND status = 'pending'
     AND expires_at <= now();

  INSERT INTO public.account_invitations(
    account_id, email, role, token_hash, status, invited_by, expires_at
  ) VALUES (
    p_account_id, v_email, 'employee', p_token_hash, 'pending',
    p_invited_by, p_expires_at
  ) RETURNING id INTO v_invitation_id;

  IF p_extra_seat THEN
    v_price := public.employee_seat_price('extra');
    INSERT INTO public.employee_seat_requests(
      account_id, requested_by_uid, employee_user_uid, employee_email,
      seat_kind, status, price_usd, invitation_id
    ) VALUES (
      p_account_id, p_invited_by, NULL, v_email,
      'extra', 'awaiting_payment', v_price, v_invitation_id
    ) RETURNING id INTO v_request_id;
    UPDATE public.account_invitations
       SET seat_request_id = v_request_id
     WHERE id = v_invitation_id;
  END IF;

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    p_account_id, p_invited_by, 'account_invitations',
    CASE WHEN p_extra_seat THEN 'invitation.create_extra_seat' ELSE 'invitation.create' END,
    v_invitation_id::text,
    jsonb_build_object(
      'email', v_email,
      'role', 'employee',
      'expires_at', p_expires_at,
      'seat_request_id', v_request_id,
      'target_auth_user_exists', v_target_uid IS NOT NULL
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'invitation_id', v_invitation_id,
    'account_id', p_account_id,
    'email', v_email,
    'expires_at', p_expires_at,
    'request_id', v_request_id,
    'price_usd', v_price,
    'target_auth_user_exists', v_target_uid IS NOT NULL
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_already_pending');
END;
$fn$;

CREATE OR REPLACE FUNCTION public.accept_account_invitation_secure(
  p_token_hash text,
  p_actor_uid uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
SET row_security = off
AS $fn$
DECLARE
  v_invitation public.account_invitations%ROWTYPE;
  v_actor_email text;
  v_actor_disabled boolean;
  v_limit integer;
  v_active_count integer;
  v_seat_status text;
BEGIN
  SELECT * INTO v_invitation
    FROM public.account_invitations i
   WHERE i.token_hash = p_token_hash
   FOR UPDATE;
  IF v_invitation.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_not_found');
  END IF;
  IF v_invitation.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_' || v_invitation.status);
  END IF;
  IF v_invitation.expires_at <= now() THEN
    UPDATE public.account_invitations SET status = 'expired'
     WHERE id = v_invitation.id;
    INSERT INTO public.audit_logs(account_id, actor_uid, table_name, op, row_pk)
    VALUES (v_invitation.account_id, p_actor_uid, 'account_invitations',
            'invitation.expire', v_invitation.id::text);
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_expired');
  END IF;

  SELECT lower(u.email), coalesce(u.disabled, false)
    INTO v_actor_email, v_actor_disabled
    FROM auth.users u
   WHERE u.id = p_actor_uid;
  IF v_actor_email IS NULL OR v_actor_disabled OR v_actor_email <> v_invitation.email THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_email_mismatch');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.accounts a
     WHERE a.id = v_invitation.account_id
       AND coalesce(a.frozen, false) = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_frozen');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_invitation.account_id::text, 701));
  IF v_invitation.seat_request_id IS NOT NULL THEN
    SELECT r.status INTO v_seat_status
      FROM public.employee_seat_requests r
     WHERE r.id = v_invitation.seat_request_id;
    IF v_seat_status IS DISTINCT FROM 'approved' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'seat_payment_pending');
    END IF;
  ELSE
    v_limit := public.account_employee_seat_limit(v_invitation.account_id);
    SELECT count(*)::integer INTO v_active_count
      FROM public.account_users au
     WHERE au.account_id = v_invitation.account_id
       AND lower(coalesce(au.role, '')) IN ('employee', 'admin')
       AND coalesce(au.disabled, false) = false;
    IF v_limit = 0 OR v_active_count >= v_limit THEN
      RETURN jsonb_build_object('ok', false, 'error', 'seat_limit_reached');
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_users au
     WHERE au.account_id = v_invitation.account_id
       AND au.user_uid = p_actor_uid
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'employee_already_member');
  END IF;

  INSERT INTO public.account_users(
    account_id, user_uid, role, disabled, email
  ) VALUES (
    v_invitation.account_id, p_actor_uid, v_invitation.role, false,
    v_invitation.email
  );
  UPDATE public.account_invitations
     SET status = 'accepted', accepted_by = p_actor_uid, accepted_at = now()
   WHERE id = v_invitation.id;
  IF v_invitation.seat_request_id IS NOT NULL THEN
    UPDATE public.employee_seat_requests
       SET employee_user_uid = p_actor_uid
     WHERE id = v_invitation.seat_request_id
       AND employee_user_uid IS NULL;
  END IF;

  INSERT INTO public.audit_logs(
    account_id, actor_uid, table_name, op, row_pk, after_row
  ) VALUES (
    v_invitation.account_id, p_actor_uid, 'account_invitations',
    'invitation.accept', v_invitation.id::text,
    jsonb_build_object('role', v_invitation.role, 'email', v_invitation.email)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'accepted',
    'account_id', v_invitation.account_id,
    'role', v_invitation.role,
    'active_account_changed', false
  );
END;
$fn$;

CREATE OR REPLACE FUNCTION public.reject_account_invitation_secure(
  p_token_hash text,
  p_actor_uid uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
SET row_security = off
AS $fn$
DECLARE
  v_invitation public.account_invitations%ROWTYPE;
  v_actor_email text;
BEGIN
  SELECT * INTO v_invitation
    FROM public.account_invitations i
   WHERE i.token_hash = p_token_hash
   FOR UPDATE;
  IF v_invitation.id IS NULL OR v_invitation.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_not_pending');
  END IF;
  SELECT lower(u.email) INTO v_actor_email FROM auth.users u WHERE u.id = p_actor_uid;
  IF v_actor_email IS NULL OR v_actor_email <> v_invitation.email THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_email_mismatch');
  END IF;
  UPDATE public.account_invitations
     SET status = 'rejected', rejected_at = now()
   WHERE id = v_invitation.id;
  INSERT INTO public.audit_logs(account_id, actor_uid, table_name, op, row_pk)
  VALUES (v_invitation.account_id, p_actor_uid, 'account_invitations',
          'invitation.reject', v_invitation.id::text);
  RETURN jsonb_build_object('ok', true, 'status', 'rejected');
END;
$fn$;

CREATE OR REPLACE FUNCTION public.revoke_account_invitation_secure(
  p_invitation_id uuid,
  p_actor_uid uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
SET row_security = off
AS $fn$
DECLARE
  v_invitation public.account_invitations%ROWTYPE;
BEGIN
  SELECT * INTO v_invitation
    FROM public.account_invitations i
   WHERE i.id = p_invitation_id
   FOR UPDATE;
  IF v_invitation.id IS NULL OR v_invitation.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invitation_not_pending');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.account_users au
     WHERE au.account_id = v_invitation.account_id
       AND au.user_uid = p_actor_uid
       AND lower(coalesce(au.role, '')) = 'owner'
       AND coalesce(au.disabled, false) = false
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden');
  END IF;
  UPDATE public.account_invitations
     SET status = 'revoked', revoked_at = now()
   WHERE id = v_invitation.id;
  UPDATE public.employee_seat_requests
     SET status = 'rejected', admin_note = 'invitation_revoked'
   WHERE invitation_id = v_invitation.id
     AND status = 'awaiting_payment';
  INSERT INTO public.audit_logs(account_id, actor_uid, table_name, op, row_pk)
  VALUES (v_invitation.account_id, p_actor_uid, 'account_invitations',
          'invitation.revoke', v_invitation.id::text);
  RETURN jsonb_build_object('ok', true, 'status', 'revoked');
END;
$fn$;

REVOKE ALL ON FUNCTION public.account_employee_seat_limit(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_account_invitation_secure(uuid, text, text, uuid, timestamptz, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_account_invitation_secure(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_account_invitation_secure(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_account_invitation_secure(uuid, uuid) FROM PUBLIC;

-- Disable the legacy GraphQL actions. They treated knowledge of an email as
-- consent and rewrote profile/JWT state for identities owned by someone else.
CREATE OR REPLACE FUNCTION public.owner_create_employee_within_limit(
  hasura_session json,
  p_email text,
  p_password text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT false, 'secure_invitation_endpoint_required', NULL::uuid, NULL::uuid,
         NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
$fn$;

CREATE OR REPLACE FUNCTION public.owner_request_extra_employee(
  hasura_session json,
  p_email text,
  p_password text
)
RETURNS SETOF public.v_rpc_result
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT false, 'secure_invitation_endpoint_required', NULL::uuid, NULL::uuid,
         NULL::uuid, NULL::text, NULL::boolean, NULL::boolean;
$fn$;

CREATE OR REPLACE FUNCTION public.superadmin_review_employee_seat_request(
  p_request_id uuid,
  p_approve boolean,
  p_note text DEFAULT NULL
)
RETURNS SETOF public.v_rpc_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $fn$
DECLARE
  v_request public.employee_seat_requests%ROWTYPE;
  v_uid uuid := nullif(public.request_uid_text(), '')::uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM public.super_admins sa
      JOIN auth.users u ON u.id = sa.user_uid
     WHERE sa.user_uid = v_uid
       AND coalesce(sa.disabled, false) = false
       AND coalesce(u.disabled, false) = false
  ) THEN
    RETURN QUERY SELECT false, 'forbidden', NULL::uuid, NULL::uuid,
      v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  SELECT * INTO v_request
    FROM public.employee_seat_requests r
   WHERE r.id = p_request_id
   FOR UPDATE;
  IF v_request.id IS NULL THEN
    RETURN QUERY SELECT false, 'request_not_found', NULL::uuid, NULL::uuid,
      v_uid, NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;
  IF v_request.invitation_id IS NULL THEN
    RETURN QUERY SELECT false, 'legacy_request_requires_secure_reissue',
      v_request.account_id, v_request.employee_user_uid, v_uid,
      NULL::text, NULL::boolean, NULL::boolean;
    RETURN;
  END IF;

  IF p_approve IS TRUE THEN
    UPDATE public.employee_seat_requests
       SET status = 'approved',
           admin_note = nullif(btrim(coalesce(p_note, '')), '')
     WHERE id = p_request_id
       AND status IN ('submitted', 'awaiting_payment');
    INSERT INTO public.employee_seat_payments(
      account_id, request_id, payment_method_id, amount,
      received_at, created_by, seat_kind
    ) VALUES (
      v_request.account_id, v_request.id, v_request.payment_method_id,
      coalesce(v_request.price_usd, 0), now(), v_uid,
      coalesce(v_request.seat_kind, 'extra')
    ) ON CONFLICT DO NOTHING;
    INSERT INTO public.audit_logs(
      account_id, actor_uid, table_name, op, row_pk, after_row
    ) VALUES (
      v_request.account_id, v_uid, 'employee_seat_requests',
      'seat.approve_invitation', v_request.id::text,
      jsonb_build_object(
        'invitation_id', v_request.invitation_id,
        'amount', v_request.price_usd,
        'note', nullif(btrim(coalesce(p_note, '')), '')
      )
    );
    RETURN QUERY SELECT true, NULL::text, v_request.account_id, NULL::uuid,
      v_uid, 'employee', NULL::boolean, false;
  ELSE
    UPDATE public.employee_seat_requests
       SET status = 'rejected',
           admin_note = nullif(btrim(coalesce(p_note, '')), '')
     WHERE id = p_request_id;
    UPDATE public.account_invitations
       SET status = 'revoked', revoked_at = now()
     WHERE id = v_request.invitation_id
       AND status = 'pending';
    INSERT INTO public.audit_logs(
      account_id, actor_uid, table_name, op, row_pk, after_row
    ) VALUES (
      v_request.account_id, v_uid, 'employee_seat_requests',
      'seat.reject_invitation', v_request.id::text,
      jsonb_build_object(
        'invitation_id', v_request.invitation_id,
        'note', nullif(btrim(coalesce(p_note, '')), '')
      )
    );
    RETURN QUERY SELECT true, NULL::text, v_request.account_id, NULL::uuid,
      v_uid, 'employee', NULL::boolean, true;
  END IF;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.set_current_account(
  hasura_session json,
  p_account uuid
)
RETURNS SETOF public.v_uuid_result
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $fn$
DECLARE
  v_uid uuid := nullif(hasura_session->>'x-hasura-user-id', '')::uuid;
BEGIN
  IF v_uid IS NULL OR p_account IS NULL THEN
    RAISE EXCEPTION 'invalid_account_selection' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM public.account_users au
      JOIN public.accounts a ON a.id = au.account_id
      JOIN auth.users u ON u.id = au.user_uid
     WHERE au.account_id = p_account
       AND au.user_uid = v_uid
       AND coalesce(au.disabled, false) = false
       AND coalesce(a.frozen, false) = false
       AND coalesce(u.disabled, false) = false
  ) THEN
    RAISE EXCEPTION 'account_selection_forbidden' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.user_current_account(user_uid, account_id)
  VALUES (v_uid, p_account)
  ON CONFLICT (user_uid) DO UPDATE
    SET account_id = excluded.account_id,
        updated_at = now();
  RETURN QUERY SELECT p_account::uuid AS id;
END;
$fn$;

COMMIT;
