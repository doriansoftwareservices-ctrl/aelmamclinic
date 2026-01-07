#!/usr/bin/env bash
set -euo pipefail

HASURA_BASE="https://mergrgclboxflnucehgb.hasura.ap-southeast-1.nhost.run"
RUNSQL_URL="$HASURA_BASE/v2/query"
email="rdftc35436@elmam.com"

run_sql () {
  local sql="$1"
  local payload
  payload=$(python3 - <<PY
import json
sql = """$sql"""
print(json.dumps({"type":"run_sql","args":{"source":"default","read_only":False,"sql":sql}}))
PY
)
  curl -sS "$RUNSQL_URL" \
    -H "Content-Type: application/json" \
    -H "x-hasura-admin-secret: $HASURA_ADMIN_SECRET" \
    -d "$payload" | python3 -m json.tool
}

run_sql "DO $$
DECLARE
  v_uid uuid;
  v_account uuid;
BEGIN
  SELECT id INTO v_uid
  FROM auth.users
  WHERE lower(email)=lower('$email')
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  SELECT account_id INTO v_account
  FROM public.account_users
  WHERE user_uid = v_uid
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'account not found';
  END IF;

  -- تثبيت دور المالك
  UPDATE public.account_users
     SET role='owner', disabled=false
   WHERE user_uid=v_uid AND account_id=v_account;

  -- مزامنة profile
  UPDATE public.profiles
     SET role='owner',
         account_id=v_account,
         disabled=false,
         email=coalesce(email, '$email')
   WHERE id=v_uid;

  -- ضمان اشتراك free نشط إن لم يوجد
  INSERT INTO public.account_subscriptions(
    account_id, plan_code, status, start_at, end_at, approved_at
  )
  SELECT v_account, 'free', 'active', now(), NULL, now()
  WHERE NOT EXISTS (
    SELECT 1 FROM public.account_subscriptions
    WHERE account_id=v_account AND status='active'
  );

  -- تطبيق صلاحيات الخطة
  PERFORM public.apply_plan_permissions(v_account, 'free');

  -- تحديث claims
  PERFORM public.auth_set_user_claims(v_uid, 'owner', v_account);

  -- تثبيت الحساب الحالي
  INSERT INTO public.user_current_account(user_uid, account_id)
  VALUES (v_uid, v_account)
  ON CONFLICT (user_uid) DO UPDATE
    SET account_id=excluded.account_id, updated_at=now();
END
$$;"
