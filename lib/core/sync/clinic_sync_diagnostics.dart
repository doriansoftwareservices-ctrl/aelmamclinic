import 'package:aelmamclinic/core/sync/clinic_sync_models.dart';

class ClinicSyncDiagnostics {
  const ClinicSyncDiagnostics._();

  static Map<String, Object?> compactStatus(ClinicSyncStatusSnapshot snapshot) {
    return <String, Object?>{
      'connectivity': snapshot.connectivity.name,
      'phase': snapshot.phase.name,
      'sync_enabled': snapshot.syncEnabled,
      'pending_outbox_count': snapshot.pendingOutboxCount,
      'failed_outbox_count': snapshot.failedOutboxCount,
      'conflict_outbox_count': snapshot.conflictOutboxCount,
      'terminal_failed_outbox_count': snapshot.terminalFailedOutboxCount,
      'last_successful_push_at': snapshot.lastSuccessfulPushAt?.toIso8601String(),
      'last_successful_pull_at': snapshot.lastSuccessfulPullAt?.toIso8601String(),
      'current_phase': snapshot.currentPhase,
      'retry_count': snapshot.retryCount,
      'next_retry_at': snapshot.nextRetryAt?.toIso8601String(),
      'has_pending_work': snapshot.hasPendingWork,
      'has_blocking_outbox': snapshot.hasBlockingOutbox,
    };
  }

  static String supportSummary(ClinicSyncStatusSnapshot snapshot) {
    final lines = <String>[
      'connectivity=${snapshot.connectivity.name}',
      'phase=${snapshot.phase.name}',
      'pending=${snapshot.pendingOutboxCount}',
      'failed=${snapshot.failedOutboxCount}',
      'conflicts=${snapshot.conflictOutboxCount}',
      'terminal=${snapshot.terminalFailedOutboxCount}',
      'lastPush=${snapshot.lastSuccessfulPushAt?.toIso8601String() ?? '-'}',
      'lastPull=${snapshot.lastSuccessfulPullAt?.toIso8601String() ?? '-'}',
      'nextRetry=${snapshot.nextRetryAt?.toIso8601String() ?? '-'}',
    ];
    return lines.join('\n');
  }
}
