# Functional Verification (Phase 7)

This checklist validates core flows after the Supabase -> Nhost migration.
Run the steps on a device or emulator with network access.

## Preconditions
- Build with backend enabled: `--dart-define=BACKEND_DISABLED=false`
- Valid Nhost config loaded (defaults or `config.json` overrides).
- Functions deployed: `admin-create-owner`, `admin-create-employee`.
- Hasura migrations/metadata applied successfully.

## Super Admin
1. Login as super admin.
2. Open Admin Dashboard.
3. Fetch clinics list.
   - Expect: list loads, no errors.
4. Create clinic owner.
   - Expect: success toast, account_id/user_uid returned.
5. Create employee for a clinic.
   - Expect: success toast, employee attached.
6. Freeze/unfreeze clinic.
   - Expect: clinic state toggles, owner cannot access when frozen.
7. Delete clinic.
   - Expect: clinic removed from list, access revoked.
8. Open chat admin inbox.
   - Expect: list loads and messages open.

## Clinic Owner
1. Login as owner.
2. Verify clinic data and statistics load.
3. Add employee (if allowed from owner flow).
4. Manage employee: disable/enable, delete.
5. Create/edit patient, appointment, prescription.
6. Sync: create items offline, then reconnect.
   - Expect: no duplicates, remote rows appear.
7. Chat: open conversation, send text + image.
   - Expect: delivery receipt and attachments render.

## Employee
1. Login as employee.
2. Verify permissions:
   - Can view allowed features only.
   - Cannot access admin dashboard.
3. Create allowed records and sync.
4. Chat: send/receive messages.

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

## Realtime / Subscriptions
1. Keep app open 20+ minutes (token refresh window).
2. Send new message from another device.
   - Expect: message arrives without restarting app.

## Expected Logs (Debug)
- `CONFIG`: Nhost URLs and secret presence.
- `SYNC`: realtime subscribed/reconnected.
- `CHAT_RPC`: warnings only on failures.
