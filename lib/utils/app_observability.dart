import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'package:aelmamclinic/utils/app_paths.dart';
import 'package:aelmamclinic/utils/logger.dart';

class ObsCode {
  ObsCode._();

  static const appFlutterError = 'APP_FLUTTER_ERROR';
  static const appZonedError = 'APP_ZONED_ERROR';
  static const appPlatformProbeFailed = 'APP_PLATFORM_PROBE_FAILED';
  static const appDataRootInitFailed = 'APP_DATA_ROOT_INIT_FAILED';
  static const appFlutterErrorPresentationFailed =
      'APP_FLUTTER_ERROR_PRESENTATION_FAILED';
  static const appDebugNotificationFailed = 'APP_DEBUG_NOTIFICATION_FAILED';
  static const appNotificationPermissionFailed =
      'APP_NOTIFICATION_PERMISSION_FAILED';
  static const appRuntimeBootstrapFailed = 'APP_RUNTIME_BOOTSTRAP_FAILED';

  static const authResolveAccountIdFailed = 'AUTH_RESOLVE_ACCOUNT_ID_FAILED';
  static const authPauseSyncFailed = 'AUTH_PAUSE_SYNC_FAILED';
  static const authResumeSyncFailed = 'AUTH_RESUME_SYNC_FAILED';
  static const authNetworkMonitorFailed = 'AUTH_NETWORK_MONITOR_FAILED';
  static const authSignOutPushDeactivateFailed =
      'AUTH_SIGN_OUT_PUSH_DEACTIVATE_FAILED';
  static const authSignOutRemoteFailed = 'AUTH_SIGN_OUT_REMOTE_FAILED';
  static const authSignOutPushDisposeFailed =
      'AUTH_SIGN_OUT_PUSH_DISPOSE_FAILED';
  static const authPendingWipeAttachmentPurgeFailed =
      'AUTH_PENDING_WIPE_ATTACHMENT_PURGE_FAILED';
  static const authSessionRestoreLocalFailed =
      'AUTH_SESSION_RESTORE_LOCAL_FAILED';
  static const authSessionRestoreRemoteFailed =
      'AUTH_SESSION_RESTORE_REMOTE_FAILED';
  static const authRefreshFetchUserFailed = 'AUTH_REFRESH_FETCH_USER_FAILED';
  static const authRefreshPermissionsFailed = 'AUTH_REFRESH_PERMISSIONS_FAILED';
  static const authRefreshClinicProfileFailed =
      'AUTH_REFRESH_CLINIC_PROFILE_FAILED';
  static const authBootstrapSyncFailed = 'AUTH_BOOTSTRAP_SYNC_FAILED';
  static const authProviderInitFailed = 'AUTH_PROVIDER_INIT_FAILED';

  static const repoAuthChangeFailed = 'REPO_AUTH_CHANGE_FAILED';
  static const repoRefreshFailed = 'REPO_REFRESH_FAILED';

  static const pushFirebaseInitFailed = 'PUSH_FIREBASE_INIT_FAILED';
  static const pushTokenRefreshDeactivateFailed =
      'PUSH_TOKEN_REFRESH_DEACTIVATE_FAILED';
  static const pushTokenRefreshUpsertFailed =
      'PUSH_TOKEN_REFRESH_UPSERT_FAILED';
  static const pushArchiveLookupFailed = 'PUSH_ARCHIVE_LOOKUP_FAILED';
  static const pushTokenUpsertFailed = 'PUSH_TOKEN_UPSERT_FAILED';
  static const pushTokenDeactivateFailed = 'PUSH_TOKEN_DEACTIVATE_FAILED';
  static const pushInitialMessageFailed = 'PUSH_INITIAL_MESSAGE_FAILED';
  static const pushBackgroundStrategySelected =
      'PUSH_BACKGROUND_STRATEGY_SELECTED';

  static const chatRealtimeMessageInsertFailed =
      'CHAT_REALTIME_MESSAGE_INSERT_FAILED';
  static const chatSupportCacheReadFailed = 'CHAT_SUPPORT_CACHE_READ_FAILED';
  static const chatSupportCacheWriteFailed = 'CHAT_SUPPORT_CACHE_WRITE_FAILED';
  static const chatSupportAgentResolveFailed =
      'CHAT_SUPPORT_AGENT_RESOLVE_FAILED';
  static const chatDeviceIdResolveFailed = 'CHAT_DEVICE_ID_RESOLVE_FAILED';
  static const chatDeviceRegistrationFailed = 'CHAT_DEVICE_REGISTRATION_FAILED';
  static const chatRpcWarning = 'CHAT_RPC_WARNING';
  static const chatAccountScopeRequired = 'CHAT_ACCOUNT_SCOPE_REQUIRED';
  static const chatLocalScopeReset = 'CHAT_LOCAL_SCOPE_RESET';
  static const chatStateTransition = 'CHAT_STATE_TRANSITION';
  static const chatRealtimeRestartFailed = 'CHAT_REALTIME_RESTART_FAILED';
  static const chatRealtimeSubscriptionFailed =
      'CHAT_REALTIME_SUBSCRIPTION_FAILED';
  static const chatOutboxFlushFailed = 'CHAT_OUTBOX_FLUSH_FAILED';

  static const syncGuardCheckFailed = 'SYNC_GUARD_CHECK_FAILED';
  static const syncStateTransition = 'SYNC_STATE_TRANSITION';
  static const syncPullScheduled = 'SYNC_PULL_SCHEDULED';
  static const syncPullSkipped = 'SYNC_PULL_SKIPPED';
  static const syncPullFailed = 'SYNC_PULL_FAILED';
  static const syncPushFailed = 'SYNC_PUSH_FAILED';
  static const syncRetryScheduled = 'SYNC_RETRY_SCHEDULED';
  static const syncResumeDirtyTablesFailed = 'SYNC_RESUME_DIRTY_TABLES_FAILED';
  static const syncStampLocalMetaReadFailed =
      'SYNC_STAMP_LOCAL_META_READ_FAILED';
  static const syncStampLocalMetaWriteFailed =
      'SYNC_STAMP_LOCAL_META_WRITE_FAILED';
  static const syncRealtimeRetryFailed = 'SYNC_REALTIME_RETRY_FAILED';
  static const syncWaitForIdleTimeout = 'SYNC_WAIT_FOR_IDLE_TIMEOUT';

  static const dbMarkChangedFailed = 'DB_MARK_CHANGED_FAILED';
  static const dbGetTableColumnsFailed = 'DB_GET_TABLE_COLUMNS_FAILED';
  static const dbCurrentAccountIdFailed = 'DB_CURRENT_ACCOUNT_ID_FAILED';
  static const dbFallbackAccountIdFailed = 'DB_FALLBACK_ACCOUNT_ID_FAILED';
  static const dbEnsureSyncIdentityFailed = 'DB_ENSURE_SYNC_IDENTITY_FAILED';
  static const dbHasLocalRowsFailed = 'DB_HAS_LOCAL_ROWS_FAILED';
  static const dbCurrentDeviceIdFailed = 'DB_CURRENT_DEVICE_ID_FAILED';
  static const statsDirtyCheckFailed = 'STATS_DIRTY_CHECK_FAILED';
  static const statsChartsRefreshFailed = 'STATS_CHARTS_REFRESH_FAILED';
}

class AppObservability {
  AppObservability._();

  static final Random _random = Random();

  static String newFlowId(String scope) {
    final normalized = scope
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final suffix = _random.nextInt(0x7fffffff).toRadixString(36);
    return '${normalized.isEmpty ? 'flow' : normalized}_$ts$suffix';
  }

  static void info({
    required String scope,
    required String code,
    String? message,
    String? flowId,
    Map<String, Object?>? context,
  }) {
    _emit(
      level: 'info',
      scope: scope,
      code: code,
      message: message,
      flowId: flowId,
      context: context,
    );
  }

  static void warn({
    required String scope,
    required String code,
    String? message,
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _emit(
      level: 'warn',
      scope: scope,
      code: code,
      message: message,
      flowId: flowId,
      context: context,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void error({
    required String scope,
    required String code,
    String? message,
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _emit(
      level: 'error',
      scope: scope,
      code: code,
      message: message,
      flowId: flowId,
      context: context,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _emit({
    required String level,
    required String scope,
    required String code,
    String? message,
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final normalizedScope =
        scope.trim().isEmpty ? 'OBS' : scope.trim().toUpperCase();
    final normalizedContext = _normalizeContext(context);
    final event = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'level': level,
      'scope': normalizedScope,
      'code': code,
      if (message != null && message.trim().isNotEmpty)
        'message': message.trim(),
      if (flowId != null && flowId.trim().isNotEmpty) 'flowId': flowId.trim(),
      if (normalizedContext.isNotEmpty) 'context': normalizedContext,
      if (error != null) 'error': '$error',
      if (stackTrace != null) 'stack': '$stackTrace',
    };

    final logData = <String, Object?>{
      'code': code,
      if (flowId != null && flowId.trim().isNotEmpty) 'flowId': flowId.trim(),
      ...normalizedContext,
    };
    final logMessage =
        message?.trim().isNotEmpty == true ? message!.trim() : code;

    switch (level) {
      case 'info':
        log.i(logMessage, tag: normalizedScope, data: logData);
        break;
      case 'warn':
        log.w(logMessage, tag: normalizedScope, data: logData, st: stackTrace);
        break;
      default:
        log.e(
          logMessage,
          tag: normalizedScope,
          error: error ?? code,
          st: stackTrace,
        );
        break;
    }

    unawaited(_appendEvent(event));
  }

  static Future<void> _appendEvent(Map<String, Object?> event) async {
    try {
      final dir = await AppPaths.logsDir();
      final file = File(p.join(dir.path, 'app_runtime_events.jsonl'));
      await file.writeAsString('${jsonEncode(event)}\n', mode: FileMode.append);
    } catch (_) {
      // Preserve caller flow even if telemetry persistence fails.
    }
  }

  static Map<String, Object?> _normalizeContext(Map<String, Object?>? input) {
    if (input == null || input.isEmpty) return const <String, Object?>{};
    final result = <String, Object?>{};
    for (final entry in input.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      final value = _normalizeValue(entry.value);
      if (value != null) {
        result[key] = value;
      }
    }
    return result;
  }

  static Object? _normalizeValue(Object? value) {
    if (value == null) return null;
    if (value is String || value is num || value is bool) return value;
    if (value is DateTime) return value.toIso8601String();
    if (value is Enum) return value.name;
    if (value is Iterable) {
      return value.map(_normalizeValue).toList(growable: false);
    }
    if (value is Map) {
      final nested = <String, Object?>{};
      for (final entry in value.entries) {
        final key = '${entry.key}'.trim();
        if (key.isEmpty) continue;
        nested[key] = _normalizeValue(entry.value);
      }
      return nested;
    }
    return '$value';
  }
}
