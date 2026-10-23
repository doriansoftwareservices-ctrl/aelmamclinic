# Notification delivery v2 — current contract, 23 October 2026

This supersedes the phase11 partial checkpoint. Local implementation and automated
backend checks are complete for this candidate. Cloud publication is being prepared
in phase14 after the owner restored Nhost CLI access to ElmamClinic. Publication,
activation and real-device acceptance are distinct states; consult the publication
ledger and [current state](README.md) for the result. No finding is closed here.

## Atomic capture and private authority

Four migrations form one server contract: `20261023001000`, `20261023002000`,
`20261023003000` and `20261023004000`. They add four private tables and seven
private tracked RPCs. Existing role permissions remain unchanged; ordinary roles
cannot query the delivery queue/control/installation tables or execute its RPCs.
The internal helpers grant no PUBLIC execute permission.

Source transactions capture future chat messages, assigned patients/new doctor
review requests, pending plans and submitted seat requests with immutable recipient
UID/installation snapshots. Rollback removes source/event/targets together. Exact
CID replay creates no second event. Name-only edits and equal assignments do not
notify. Activation never backfills historical sources or replays uncertain old
completed notifications. Set-based capture has no 1000-recipient truncation.

Recipient checks use the actual current Hasura role, active membership, clinic
freeze/features, doctor assignment, chat participation/mute/archive/block and the
active system-admin registry. A role supplied by a device token grants no authority.
The final SQL admission repeats current authority, rollout state, exact active
registration/token and at least 20 seconds of the server-clock lease immediately
before provider transport. Token rotation resolves the captured installation's
current registration; a later installation cannot join a historical snapshot.

## Installation binding, provider result and device receipt

Registration verifies Auth and derives the UID from that identity. A random
installation UUID, 32-byte device secret and monotonically increasing exact client
revision bind each installation. The server stores the secret hash. Request hashes
make lost-response replay idempotent; stale revisions and changed requests fail.
A late logout from a former user cannot retire a newer user's binding. Ordinary
protocol2 token CRUD is blocked by SQL; only the reviewed endpoint owns this write.
Protocol2 currently admits Android installations.

The real HTTP-v1 adapter signs a bounded OAuth request, caches its token by monotonic
time and uses a seven-second combined transport deadline. Only a typed success
with a same-project provider message reference counts as known acceptance.
Only typed UNREGISTERED permits exact compare-and-set token retirement. The data-only
payload contains routing identities, never a patient name or chat text. Missing
credentials are detected before claiming targets, preserving their retry budget.

Provider acceptance, persisted local display and device ACK are separate evidence.
Unacknowledged accepted targets retry after three minutes with the same event,
target and nonce, up to eight attempts. Partial retries preserve successful targets;
late ACK resolves exhausted targets. ACK-before-finish and send-before-crash races
are covered. No exactly-once external transport guarantee is claimed.

## Client display and navigation

`lib/features/notifications/` owns the strict envelope, device API, patient resolver,
AES-256-GCM delivery journal and delivery client. Sensitive journal values are
encrypted before SQLite/WAL using a random key in system secure storage. Missing
keys fail closed without deleting the journal. Separate physical SQLite connections,
bounded asynchronous BEGIN retries and no transaction-body replay handle foreground
and background isolate contention.

Stable negative OS IDs persist before display. A completed display is committed
before ACK; failed ACK retries ACK alone. Completed dedup records are intentionally
retained, with indexed pending-work selection. No automatic destructive pruning is
implemented. Each display and foreground tap rechecks current actor/clinic scope;
taps validate the current Bearer identity on the server. Remote patient UUIDs resolve
through scoped sync identity, with a bounded permitted pull if needed, never patient0.

Android FCM owns OS display; Android realtime/local assignment paths no longer create
a duplicate OS alert. Windows foreground realtime behavior remains available.
Session generations, serialized registration revisions, logout cleanup, rotation,
initialization recovery and scoped foreground retries are wired. Background handling
uses the installation capability and current server authority without refreshing the
shared Auth SDK. A reloaded local UID is a suppression hint, not authorization.

## Deployment and activation

The three old notification routes are now secret-protected v2 wakeup aliases and
`notify_utils.js` no longer contains the legacy sender/completion implementation.
The new routes are `notify-dispatch-v2`, `notification-register-v2` and
`notification-receipt-v2`. A secret-protected minute cron wakes the dispatcher;
existing event hooks remain wakeups. Durable source capture does not depend on
successful webhook delivery.

Capture and dispatch default OFF. Deploy all four migrations, their private metadata,
cron and matching Functions as one reviewed candidate, then reconcile the actual
catalog, metadata consistency, unchanged permissions/admin and route behavior before
activation. Do not enable either flag with only part of this contract installed.
The fresh CLI secret-name inspection found no supported Firebase credential settings;
keep dispatch OFF until valid credentials for the app's Firebase project exist.
Never manufacture a service account or reuse an unrelated project's key.

For rollback, disable dispatch/capture and retain the durable queue, registration and
receipt contract. Do not resurrect the legacy sender while protocol2 devices exist.
Do not delete private tables or business data as an operational rollback. No old
completed notifications should be replayed.

## Automated evidence and user acceptance

Evidence lives in `C:/Users/zidan/Downloads/ELMAMCLINIC_REPAIR_20261021/evidence`:

- `phase12_node_frozen_v4.json`: 244 passes in 16 files, network fenced, source hashes
  preserved; no actual FCM transport.
- `phase12_SQL_regression_v1.json`: 64 actual PostgreSQL14 cases across capture,
  final admission and installation binding with all four migrations installed.
- `phase12_device_hasura_v3.json`: 13 actual HTTP-handler/Hasura2.48.10/PG14 cases;
  Auth identity transport is simulated.
- `phase12_authority_worker_regression_v2.json`: 19 current-authority and 12 worker
  integration cases; provider/ACK simulation is explicitly recorded.
- `phase13_backend_candidate_metadata_delta.json`: only four private tables, seven
  private RPCs and one cron are new; existing metadata is semantically preserved,
  allowing only 12 explicit false aggregation defaults.
- `phase13_complete_v5_focus.json`: 97 Flutter cases pass, including delivery,
  lifecycle, foreground tap identity and trusted-clock checks. The complete suite
  is recorded separately after its completion; focused success does not replace it.

The owner reserved actual device tests and final acceptance. Their matrix includes
Android foreground/background/restart, permissions denied, offline/reconnect, account
switch, token rotation, clinic/role removal, missing patient identity, duplicate FCM,
Windows foreground behavior and real Firebase acceptance. None is checked as passed
by simulated transport. Clinical/chat records remain authoritative through sync.
