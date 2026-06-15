import 'dart:async';

import 'package:aelmamclinic/core/sync/clinic_connectivity_monitor.dart';
import 'package:aelmamclinic/core/sync/clinic_sync_models.dart';
import 'package:aelmamclinic/services/sync_outbox_service.dart';
import 'package:aelmamclinic/services/sync_service.dart';

class ClinicSyncEngine {
  ClinicSyncEngine({
    required SyncService syncService,
    SyncOutboxService outbox = const SyncOutboxService(),
    ClinicConnectivityMonitor? connectivityMonitor,
  })  : _sync = syncService,
        _outbox = outbox,
        _connectivity = connectivityMonitor ?? ClinicConnectivityMonitor();

  final SyncService _sync;
  final SyncOutboxService _outbox;
  final ClinicConnectivityMonitor _connectivity;
  StreamSubscription<ClinicConnectivityStatus>? _connectivitySub;
  bool _started = false;

  ClinicConnectivityStatus get connectivityStatus => _connectivity.status;
  SyncRuntimeSnapshot get runtimeSnapshot => _sync.runtimeSnapshot;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _connectivity.start();
    _connectivitySub = _connectivity.changes.listen((status) {
      if (status == ClinicConnectivityStatus.online) {
        unawaited(runNow(reason: 'connectivity_online', forceRetry: true));
      }
    });
  }

  Future<void> runNow({
    String reason = 'manual',
    bool forceRetry = false,
  }) async {
    await start();
    final online = await _connectivity.ensureOnlineForManualSync();
    if (!online) return;
    if (forceRetry) {
      await _outbox.forceRetryPending(accountId: _sync.accountId);
    }
    await _sync.pushPendingOutbox(reason: reason);
    await _sync.pushAll();
    await _sync.pullAll(reason: reason);
  }

  Future<ClinicSyncStatusSnapshot> snapshot() async {
    await start();
    final runtime = _sync.runtimeSnapshot;
    final outboxDiagnostics = await _outbox.diagnostics(
      accountId: runtime.accountId.trim().isEmpty ? null : runtime.accountId,
    );
    final byStatus = outboxDiagnostics['by_status'] is Map
        ? Map<String, Object?>.from(outboxDiagnostics['by_status'] as Map)
        : const <String, Object?>{};
    int count(String key) => (byStatus[key] as num?)?.toInt() ?? 0;
    return ClinicSyncStatusSnapshot(
      generatedAt: DateTime.now(),
      connectivity: _connectivity.status,
      phase: _phaseFromRuntime(runtime.phase),
      syncEnabled: runtime.syncEnabled,
      pendingOutboxCount: (outboxDiagnostics['pending_count'] as num?)?.toInt() ?? 0,
      failedOutboxCount: count('failed'),
      conflictOutboxCount: count('conflict'),
      terminalFailedOutboxCount: count('terminal_failed'),
      lastSuccessfulPullAt: runtime.lastPullAt,
      lastSuccessfulPushAt: runtime.lastOutboxPushAt,
      lastErrorCode: null,
      lastErrorMessage: null,
      currentPhase: runtime.phaseReason,
      retryCount: (outboxDiagnostics['max_retry_count'] as num?)?.toInt() ?? 0,
      nextRetryAt: DateTime.tryParse(
        outboxDiagnostics['next_retry_at']?.toString() ?? '',
      ),
    );
  }

  ClinicSyncPhase _phaseFromRuntime(String phase) {
    switch (phase) {
      case 'pushing':
        return ClinicSyncPhase.pushing;
      case 'pulling':
        return ClinicSyncPhase.pulling;
      case 'paused':
        return ClinicSyncPhase.paused;
      case 'blocked':
        return ClinicSyncPhase.blocked;
      case 'failed':
        return ClinicSyncPhase.failed;
      default:
        if (_connectivity.status == ClinicConnectivityStatus.offline) {
          return ClinicSyncPhase.waitingForConnection;
        }
        return ClinicSyncPhase.idle;
    }
  }

  Future<void> dispose() async {
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    await _connectivity.dispose();
    _started = false;
  }
}
