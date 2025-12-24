# Functional Verification (Phase 7)

This checklist validates core flows after the Supabase -> Nhost migration.
Run the steps on a device or emulator with network access.

## Preconditions
- Build with backend enabled: `--dart-define=BACKEND_DISABLED=false`
- Valid Nhost config loaded (defaults or `config.json` overrides).
- Functions deployed: `admin-create-owner`, `admin-create-employee`.
- Hasura migrations/metadata applied successfully.
- Billing metadata functions enabled: `my_account_plan`, `create_subscription_request`,
  `admin_approve_subscription_request`, `admin_reject_subscription_request`,
  `admin_payment_stats_*`, `expire_account_subscriptions`.
- Cron trigger `expire_account_subscriptions_daily` applied.

## Super Admin
1. Login as super admin.
2. Open Admin Dashboard.
3. Fetch clinics list.
   - Expect: list loads, no errors.
4. Create clinic owner.
   - Expect: success toast, account_id/user_uid returned.
5. Create employee for a clinic (paid plan only).
   - Expect: FREE → blocked with "plan is free" error.
   - Expect: MONTH/YEAR → success toast, employee attached.
6. Freeze/unfreeze clinic.
   - Expect: clinic state toggles, owner cannot access when frozen.
7. Delete clinic.
   - Expect: clinic removed from list, access revoked.
8. Open chat admin inbox.
   - Expect: list loads and messages open.
9. Subscriptions: approve/reject request.
   - Expect: status transitions, plan updated, audit log entry.
10. Payment methods CRUD.
   - Expect: add/edit/delete works, list refreshes.
11. Payment stats:
   - Methods / By plan / Monthly / Daily toggles return data or empty state.

## Clinic Owner (FREE)
1. Sign up → self_create_account bootstrap.
   - Expect: account created, plan FREE, allowed tabs only.
2. Try opening PRO feature (e.g., Repository).
   - Expect: PRO badge + redirect to "My Plan".
3. "My Plan":
   - Expect: current plan shows FREE.
4. Start upgrade → payment screen:
   - Missing payment methods → user sees proper error.
   - With payment methods → submit request with proof/refs.

## Clinic Owner (PAID)
1. Login as owner.
2. Verify clinic data and statistics load.
3. Add employee (if allowed from owner flow).
4. Manage employee: disable/enable, delete.
5. Create/edit patient, appointment, prescription.
6. Sync: create items offline, then reconnect.
   - Expect: no duplicates, remote rows appear.
7. Chat: open conversation, send text + image.
   - Expect: delivery receipt and attachments render.

## Employee (PAID)
1. Login as employee.
2. Verify permissions:
   - Can view allowed features only.
   - Cannot access admin dashboard.
3. Create allowed records and sync.
4. Chat: send/receive messages.

## Employee (after plan expiry)
1. Downgrade account to FREE (admin_set_account_plan or expire job).
2. Employee tries to login.
   - Expect: blocked and signed out.
3. Owner renews plan to MONTH/YEAR.
   - Expect: employee login restored.

## Offline + Recovery
1. Start app offline.
2. Create local data (patient/item).
3. Restore network.
   - Expect: sync push succeeds, no duplicate records.

## Storage / Attachments
1. Send image in chat.
2. Verify:
   - Upload succeeds.
   - Signed URL works (or public URL if configured).
   - Attachment cached locally (no re-download).

## Subscription Proofs
1. Submit a subscription request with proof file.
2. From Super Admin:
   - Open proof URL.
   - Approve or reject with note.
3. Verify:
   - Subscription updates.
   - Audit logs contain plan action.

## Realtime / Subscriptions
1. Keep app open 20+ minutes (token refresh window).
2. Send new message from another device.
   - Expect: message arrives without restarting app.

## Failure Scenarios
1. Network drop during proof upload.
   - Expect: clear error, retry possible.
2. Duplicate upgrade request (pending exists).
   - Expect: server rejects with "pending request exists".
3. Plan expiry job (dry run):
   - Run: `expire_account_subscriptions(p_dry_run=true)` and ensure counts match.

## Expected Logs (Debug)
- `CONFIG`: Nhost URLs and secret presence.
- `SYNC`: realtime subscribed/reconnected.
- `CHAT_RPC`: warnings only on failures.
