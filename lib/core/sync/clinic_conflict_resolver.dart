import 'package:aelmamclinic/core/sync/clinic_sync_domains.dart';

enum ClinicConflictPolicy {
  appendOnly,
  lastWriteWins,
  mergeAware,
  serverAuthoritative,
}

class ClinicConflictDecision {
  const ClinicConflictDecision({
    required this.policy,
    required this.terminal,
    required this.conflict,
    required this.retryable,
    required this.code,
    required this.message,
  });

  final ClinicConflictPolicy policy;
  final bool terminal;
  final bool conflict;
  final bool retryable;
  final String code;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
        'policy': policy.name,
        'terminal': terminal,
        'conflict': conflict,
        'retryable': retryable,
        'code': code,
        'message': message,
      };
}

class ClinicConflictResolver {
  const ClinicConflictResolver();

  static const Set<String> appendOnlyTables = <String>{
    'financial_logs',
    'purchases',
    'consumptions',
  };

  static const Set<String> lastWriteWinsTables = <String>{
    'clinic_profile',
    'alert_settings',
  };

  static const Set<String> mergeAwareTables = <String>{
    'patients',
    'appointments',
    'doctors',
    'items',
    'medical_services',
    'patient_services',
    'prescriptions',
    'prescription_items',
  };

  static const Set<String> serverAuthoritativeTables = <String>{
    'accounts',
    'account_users',
    'account_feature_permissions',
    'employee_seat_payments',
    'subscription_payments',
    'employees_salaries',
  };

  ClinicConflictPolicy policyForTable(String table) {
    final normalized = table.trim();
    if (appendOnlyTables.contains(normalized)) {
      return ClinicConflictPolicy.appendOnly;
    }
    if (serverAuthoritativeTables.contains(normalized)) {
      return ClinicConflictPolicy.serverAuthoritative;
    }
    if (mergeAwareTables.contains(normalized)) {
      return ClinicConflictPolicy.mergeAware;
    }
    if (lastWriteWinsTables.contains(normalized)) {
      return ClinicConflictPolicy.lastWriteWins;
    }
    final domain = ClinicSyncDomains.domainForTable(normalized);
    if (domain == ClinicSyncDomain.finance) {
      return ClinicConflictPolicy.serverAuthoritative;
    }
    return ClinicConflictPolicy.mergeAware;
  }

  bool shouldUseTombstone(String table) {
    return !appendOnlyTables.contains(table.trim());
  }

  bool shouldUseReversal(String table) {
    return appendOnlyTables.contains(table.trim());
  }

  ClinicConflictDecision classifyError({
    required String table,
    required String operationType,
    required String errorCode,
    required String message,
  }) {
    final normalizedCode = errorCode.trim().toLowerCase();
    final normalizedMessage = message.trim().toLowerCase();
    final policy = policyForTable(table);
    final isConflict = normalizedCode.contains('conflict') ||
        normalizedMessage.contains('conflict') ||
        normalizedMessage.contains('idempotency_payload_mismatch') ||
        normalizedCode.contains('version');
    final isAuthOrPermission = normalizedCode.contains('permission') ||
        normalizedCode.contains('disabled') ||
        normalizedCode.contains('frozen') ||
        normalizedCode.contains('auth') ||
        normalizedMessage.contains('permission') ||
        normalizedMessage.contains('forbidden');
    final transient = normalizedCode.contains('timeout') ||
        normalizedCode.contains('network') ||
        normalizedCode.contains('temporar') ||
        normalizedCode.contains('503') ||
        normalizedCode.contains('502') ||
        normalizedCode.contains('504') ||
        normalizedMessage.contains('timeout') ||
        normalizedMessage.contains('network') ||
        normalizedMessage.contains('temporar');
    return ClinicConflictDecision(
      policy: policy,
      terminal: isConflict || isAuthOrPermission || !transient,
      conflict: isConflict,
      retryable: transient && !isConflict && !isAuthOrPermission,
      code: normalizedCode.isEmpty ? 'sync_error' : normalizedCode,
      message: message,
    );
  }
}
