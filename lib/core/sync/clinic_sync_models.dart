enum ClinicConnectivityStatus { unknown, offline, online }

enum ClinicSyncPhase {
  idle,
  waitingForConnection,
  pushing,
  pulling,
  paused,
  failed,
  blocked,
}

enum ClinicOutboxStatus {
  queued,
  inFlight,
  failed,
  succeeded,
  conflict,
  terminalFailed,
}

class ClinicOutboxStatusCodec {
  const ClinicOutboxStatusCodec._();

  static String encode(ClinicOutboxStatus status) {
    switch (status) {
      case ClinicOutboxStatus.queued:
        return 'queued';
      case ClinicOutboxStatus.inFlight:
        return 'in_flight';
      case ClinicOutboxStatus.failed:
        return 'failed';
      case ClinicOutboxStatus.succeeded:
        return 'succeeded';
      case ClinicOutboxStatus.conflict:
        return 'conflict';
      case ClinicOutboxStatus.terminalFailed:
        return 'terminal_failed';
    }
  }

  static ClinicOutboxStatus decode(Object? value) {
    final text = value?.toString().trim().toLowerCase();
    switch (text) {
      case 'in_flight':
      case 'inflight':
        return ClinicOutboxStatus.inFlight;
      case 'failed':
        return ClinicOutboxStatus.failed;
      case 'succeeded':
        return ClinicOutboxStatus.succeeded;
      case 'conflict':
        return ClinicOutboxStatus.conflict;
      case 'terminal_failed':
      case 'terminalfailed':
        return ClinicOutboxStatus.terminalFailed;
      case 'queued':
      default:
        return ClinicOutboxStatus.queued;
    }
  }
}

class ClinicSyncStatusSnapshot {
  const ClinicSyncStatusSnapshot({
    required this.generatedAt,
    required this.connectivity,
    required this.phase,
    required this.syncEnabled,
    required this.pendingOutboxCount,
    required this.failedOutboxCount,
    required this.conflictOutboxCount,
    required this.terminalFailedOutboxCount,
    this.lastSuccessfulPushAt,
    this.lastSuccessfulPullAt,
    this.lastErrorCode,
    this.lastErrorMessage,
    this.currentDomain,
    this.currentPhase,
    this.retryCount = 0,
    this.nextRetryAt,
  });

  final DateTime generatedAt;
  final ClinicConnectivityStatus connectivity;
  final ClinicSyncPhase phase;
  final bool syncEnabled;
  final int pendingOutboxCount;
  final int failedOutboxCount;
  final int conflictOutboxCount;
  final int terminalFailedOutboxCount;
  final DateTime? lastSuccessfulPushAt;
  final DateTime? lastSuccessfulPullAt;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final String? currentDomain;
  final String? currentPhase;
  final int retryCount;
  final DateTime? nextRetryAt;

  bool get hasPendingWork => pendingOutboxCount > 0;
  bool get hasBlockingOutbox =>
      conflictOutboxCount > 0 || terminalFailedOutboxCount > 0;
  bool get hasTransientFailures => failedOutboxCount > 0;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'generated_at': generatedAt.toIso8601String(),
      'connectivity': connectivity.name,
      'phase': phase.name,
      'sync_enabled': syncEnabled,
      'pending_outbox_count': pendingOutboxCount,
      'failed_outbox_count': failedOutboxCount,
      'conflict_outbox_count': conflictOutboxCount,
      'terminal_failed_outbox_count': terminalFailedOutboxCount,
      'last_successful_push_at': lastSuccessfulPushAt?.toIso8601String(),
      'last_successful_pull_at': lastSuccessfulPullAt?.toIso8601String(),
      'last_error_code': lastErrorCode,
      'last_error_message': lastErrorMessage,
      'current_domain': currentDomain,
      'current_phase': currentPhase,
      'retry_count': retryCount,
      'next_retry_at': nextRetryAt?.toIso8601String(),
    };
  }
}

class ClinicOutboxEntry {
  const ClinicOutboxEntry({
    required this.id,
    required this.operationType,
    required this.entityTable,
    required this.clientMutationId,
    required this.accountId,
    required this.deviceId,
    required this.payload,
    required this.status,
    required this.retryCount,
    required this.createdAt,
    required this.updatedAt,
    this.entityId,
    this.remoteId,
    this.localId,
    this.localReference,
    this.nextRetryAt,
    this.lastAttemptAt,
    this.lockedAt,
    this.lastErrorCode,
    this.lastErrorMessage,
    this.lastResponse,
    this.completedAt,
  });

  final String id;
  final String operationType;
  final String entityTable;
  final int? entityId;
  final String? remoteId;
  final String clientMutationId;
  final String accountId;
  final String deviceId;
  final int? localId;
  final Map<String, Object?> payload;
  final Map<String, Object?>? localReference;
  final ClinicOutboxStatus status;
  final int retryCount;
  final DateTime? nextRetryAt;
  final DateTime? lastAttemptAt;
  final DateTime? lockedAt;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final Map<String, Object?>? lastResponse;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'operation_type': operationType,
      'entity_table': entityTable,
      'entity_id': entityId,
      'remote_id': remoteId,
      'client_mutation_id': clientMutationId,
      'account_id': accountId,
      'device_id': deviceId,
      'local_id': localId,
      'payload': payload,
      'local_reference': localReference,
      'status': ClinicOutboxStatusCodec.encode(status),
      'retry_count': retryCount,
      'next_retry_at': nextRetryAt?.toIso8601String(),
      'last_attempt_at': lastAttemptAt?.toIso8601String(),
      'locked_at': lockedAt?.toIso8601String(),
      'last_error_code': lastErrorCode,
      'last_error_message': lastErrorMessage,
      'last_response': lastResponse,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
    };
  }
}
