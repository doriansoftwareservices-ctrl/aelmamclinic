// lib/providers/auth_provider.dart
//
// مزوّد حالة المصادقة + صلاحيات الميزات + Bootstrap للمزامنة.
// النقاط الأساسية:
// - توحيد مصدر الحقيقة مع AuthSupabaseService (تفويض bootstrap/guards للمزامنة).
// - تخزين محلي خفيف (SharedPreferences) لآخر هوية + صلاحيات الميزات.
// - تحديث role/isSuperAdmin بصيغة موحّدة (superadmin بحروف صغيرة).
// - إزالة إدارة SyncService المباشرة من المزوّد (لا مؤقّت 60 ثانية)،
//   والاعتماد على bootstrapSyncForCurrentUser من AuthSupabaseService الذي يشمل:
//   parity v3 + ربط push debounced + Realtime + حراسة الحساب/الموظف.

import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:nhost_dart/nhost_dart.dart';
import 'package:nhost_sdk/nhost_sdk.dart' show AuthResponse;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aelmamclinic/core/features.dart'; // FeatureKeys.chat
import 'package:aelmamclinic/core/auth_role_state.dart';
import 'package:aelmamclinic/models/account_policy.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/models/feature_permissions.dart';
import 'package:aelmamclinic/services/nhost_auth_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/device_id_service.dart';
import 'package:aelmamclinic/services/notification_service.dart';
import 'package:aelmamclinic/services/network_status_service.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/push_notifications_service.dart';
import 'package:aelmamclinic/services/sync_service.dart';
import 'package:aelmamclinic/services/backup_restore_service.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/local/chat_local_store.dart';
import 'package:aelmamclinic/services/attachment_cache.dart';
import 'package:aelmamclinic/models/storage_type.dart';
import 'package:aelmamclinic/utils/app_observability.dart';
import 'package:aelmamclinic/utils/app_error_reporter.dart';
import 'package:aelmamclinic/utils/logger.dart';

/// مفاتيح التخزين المحلي
const _kUid = 'auth.uid';
const _kEmail = 'auth.email';
const _kAccountId = 'auth.accountId';
const _kRole = 'auth.role';
const _kDisabled = 'auth.disabled';
const _kPlanCode = 'auth.planCode';
const _kPlanEndAt = 'auth.planEndAt';
const _kChatCode = 'auth.chatCode';
const _kDeviceId = 'auth.deviceId';
const _kLastNetCheckAt = 'auth.lastNetCheckAt';
const int _kNetCheckIntervalMinutes = 5; // فحص شبكة كل 5 دقائق

// مفاتيح صلاحيات الميزات + CRUD
const _kAllowedFeatures = 'auth.allowedFeatures'; // CSV
const _kAllowAllFeatures = 'auth.allowAllFeatures';
const _kCanCreate = 'auth.canCreate';
const _kCanUpdate = 'auth.canUpdate';
const _kCanDelete = 'auth.canDelete';

const bool _kEnableAuthDiagLogs = bool.fromEnvironment(
  'AUTH_DIAGNOSTIC_LOGS',
  defaultValue: !kReleaseMode,
);

const String _kAuthDiagTag = 'AUTH_DIAG';

void _authDiag(String message, {Map<String, Object?>? context}) {
  if (!_kEnableAuthDiagLogs) return;
  log.d(
    context == null || context.isEmpty
        ? message
        : '$message | ctx=${context.toString()}',
    tag: _kAuthDiagTag,
  );
}

void _authDiagWarn(
  String message, {
  Map<String, Object?>? context,
  StackTrace? stackTrace,
}) {
  if (!_kEnableAuthDiagLogs) return;
  log.w(
    context == null || context.isEmpty
        ? message
        : '$message | ctx=${context.toString()}',
    tag: _kAuthDiagTag,
    st: stackTrace,
  );
}

void _authDiagError(
  String message, {
  Map<String, Object?>? context,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (!_kEnableAuthDiagLogs) return;
  log.e(
    context == null || context.isEmpty
        ? message
        : '$message | ctx=${context.toString()}',
    tag: _kAuthDiagTag,
    error: error,
    st: stackTrace,
  );
}

/// نتيجة تحقق حراسة الحساب بعد المزامنة من الشبكة.
enum AuthAccountGuardResult {
  ok,
  disabled,
  accountFrozen,
  noAccount,
  planUpgradeRequired,
  signedOut,
  transientFailure,
  unknown,
}

/// حالة التحقق بعد تحديث بيانات المستخدم من الشبكة وحراسة الحساب.
enum AuthSessionStatus {
  success,
  isolationRequired,
  disabled,
  accountFrozen,
  noAccount,
  planUpgradeRequired,
  signedOut,
  networkError,
  unknown,
}

/// نتيجة تفصيلية لدورة التحقق بعد تسجيل الدخول/استئناف الجلسة.
class AuthSessionResult {
  final AuthSessionStatus status;
  final Object? error;
  final StackTrace? stackTrace;

  const AuthSessionResult._(this.status, {this.error, this.stackTrace});

  const AuthSessionResult.success() : this._(AuthSessionStatus.success);
  const AuthSessionResult.isolationRequired()
      : this._(AuthSessionStatus.isolationRequired);
  const AuthSessionResult.disabled() : this._(AuthSessionStatus.disabled);
  const AuthSessionResult.accountFrozen()
      : this._(AuthSessionStatus.accountFrozen);
  const AuthSessionResult.noAccount() : this._(AuthSessionStatus.noAccount);
  const AuthSessionResult.planUpgradeRequired()
      : this._(AuthSessionStatus.planUpgradeRequired);
  const AuthSessionResult.signedOut() : this._(AuthSessionStatus.signedOut);
  const AuthSessionResult.networkError({Object? error, StackTrace? stackTrace})
      : this._(AuthSessionStatus.networkError,
            error: error, stackTrace: stackTrace);
  const AuthSessionResult.unknown({Object? error, StackTrace? stackTrace})
      : this._(AuthSessionStatus.unknown, error: error, stackTrace: stackTrace);

  bool get isSuccess => status == AuthSessionStatus.success;
}

class AuthProvider extends ChangeNotifier {
  final NhostAuthService _auth;

  /// { uid, email, accountId, role, isSuperAdmin, disabled? }
  Map<String, dynamic>? currentUser;

  /// معرّف الجهاز الثابت للمزامنة
  String? deviceId;

  // === صلاحيات الميزات + CRUD ===
  bool _allowAllFeatures = false;
  Set<String> _allowedFeatures = <String>{};
  bool _canCreate = true;
  bool _canUpdate = true;
  bool _canDelete = true;
  bool _permissionsLoaded = false;
  String? _permissionsError;
  bool _autoCreateAttempted = false;
  ClinicProfileInput? _pendingClinicProfile;
  bool _allowAutoCreateAccount = false;
  bool _pendingLocalWipe = false;
  String? _pendingWipeAccountId;
  String? _lastBackfilledSyncAccountId;
  StreamSubscription<QueryResult>? _planSub;
  String? _planSubUid;

  Set<String> get allowedFeatures => _allowedFeatures;
  bool get allowAllFeatures => _allowAllFeatures;
  bool get canCreate => isSuperAdmin || (_permissionsLoaded && _canCreate);
  bool get canUpdate => isSuperAdmin || (_permissionsLoaded && _canUpdate);
  bool get canDelete => isSuperAdmin || (_permissionsLoaded && _canDelete);
  bool get permissionsLoaded => _permissionsLoaded;
  String? get permissionsError => _permissionsError;

  /// السماح يعتمد على allow_all أو على القائمة المخزنة فقط (fail-closed).
  bool featureAllowed(String featureKey) {
    if (isSuperAdmin) return true;
    if (featureKey == FeatureKeys.patientQuestions) {
      return planCode.toLowerCase() != 'free' && !_isPlanExpired();
    }
    if (!_permissionsLoaded) return false;
    if (_allowAllFeatures) return true;
    return _allowedFeatures.contains(featureKey);
  }

  /// اختصار مفيد لميزة الدردشة
  bool get chatEnabled => isSuperAdmin || featureAllowed(FeatureKeys.chat);

  // === إدارة تدفّق المصادقة ===
  StreamSubscription<AuthenticationState>? _authSub;
  StreamSubscription<String>? _patientAlertSub;
  Timer? _patientAlertDebounce;
  Set<int> _pendingPatientAlerts = <int>{};
  int? _patientAlertDoctorId;
  Future<bool>? _refreshInFlight;
  Future<AuthAccountGuardResult>? _guardInFlight;
  DateTime? _lastRefreshAttemptAt;
  bool _lastRefreshSuccess = false;
  bool _offlineSession = false;
  bool? _debugHasNhostSessionOverride;
  StreamSubscription<bool>? _netSub;
  DateTime? _lastOnlineSyncAt;
  bool _authFlowRunning = false;
  DateTime? _lastGuardOkAt;
  bool _lastGuardOk = false;
  DateTime? _lastSessionRestoreAttemptAt;
  Future<AuthSessionResult>? _sessionReconcileInFlight;
  Future<void>? _initInFlight;
  bool _initComplete = false;
  Object? _initError;

  /*──────── Getters ────────*/
  bool get isLoggedIn => currentUser != null;
  bool get isInitializing => _initInFlight != null && !_initComplete;
  bool get isInitComplete => _initComplete;
  Object? get initError => _initError;
  bool get hasLocalSession => currentUser != null;
  String? get accessToken => _auth.accessToken;
  String? get uid => currentUser?['uid'] as String?;
  String? get email => currentUser?['email'] as String?;
  String? get role => currentUser?['role'] as String?;
  String? get accountId => currentUser?['accountId'] as String?;
  String? get chatCode => currentUser?['chatCode'] as String?;
  String? get chatCodeSafe {
    final raw = currentUser?['chatCode'] ?? currentUser?['chat_code'];
    final value = raw?.toString();
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  SyncService? get sync => _auth.sync;

  Future<void> pauseSync() => _auth.pauseSync();
  Future<void> resumeSync() => _auth.resumeSync();
  Future<void> waitForSyncIdle(
          {Duration timeout = const Duration(seconds: 10)}) =>
      _auth.waitForSyncIdle(timeout: timeout);
  String get planCode =>
      (currentUser?['planCode'] as String?)?.toLowerCase() ?? 'free';
  DateTime? get planEndAt => _readPlanEndAt(currentUser?['planEndAt']);
  bool get isPro => isSuperAdmin || (planCode != 'free' && !_isPlanExpired());
  bool get isDisabled => (currentUser?['disabled'] as bool?) ?? false;
  bool get isSuperAdmin => currentUser?['isSuperAdmin'] == true;
  bool get isOffline => _offlineSession;
  bool get hasNhostSession =>
      _debugHasNhostSessionOverride ?? _auth.currentUser != null;
  bool get hasSuperAdminSessionRole {
    final user = _auth.currentUser;
    if (user == null) return false;
    final roles = user.roles.map((r) => r.toLowerCase()).toList();
    return roles.contains('superadmin') ||
        user.defaultRole.toLowerCase() == 'superadmin';
  }
  bool get requiresLocalIsolationWipe => _pendingLocalWipe;
  bool get hasAccountContext =>
      (currentUser?['accountId'] ?? '').toString().trim().isNotEmpty;
  bool get needsRemoteSessionRecovery => hasLocalSession && !hasNhostSession;
  bool get needsAccountContextResolution =>
      hasLocalSession &&
      !requiresLocalIsolationWipe &&
      !isSuperAdmin &&
      !hasAccountContext;
  bool get canEnterClinicShell =>
      hasLocalSession &&
      !requiresLocalIsolationWipe &&
      !isSuperAdmin &&
      hasAccountContext;
  bool get canEnterRemoteAdminShell =>
      hasLocalSession &&
      !requiresLocalIsolationWipe &&
      isSuperAdmin &&
      hasNhostSession &&
      hasSuperAdminSessionRole;
  bool get hasReadyAppShell => canEnterClinicShell || canEnterRemoteAdminShell;
  bool get canRunRemoteBoundServices =>
      !requiresLocalIsolationWipe &&
      hasNhostSession &&
      (isSuperAdmin || hasAccountContext);
  String get sessionTopologyState {
    if (!hasLocalSession) return 'signed_out';
    if (requiresLocalIsolationWipe) return 'local_waiting_isolation_wipe';
    if (canEnterRemoteAdminShell) return 'superadmin_remote_ready';
    if (canEnterClinicShell && hasNhostSession) return 'clinic_remote_ready';
    if (canEnterClinicShell) return 'clinic_local_only';
    if (needsRemoteSessionRecovery) return 'local_waiting_remote_restore';
    if (needsAccountContextResolution) return 'local_waiting_account_context';
    return 'local_unclassified';
  }

  bool get isOwnerOrAdmin {
    if (isSuperAdmin) return true;
    final r = role?.toLowerCase();
    return r == 'owner' || r == 'admin';
  }

  bool get hasPendingLocalWipe => _pendingLocalWipe;

  String _newAuthFlow(String label) =>
      AppObservability.newFlowId('auth_$label');

  Map<String, Object?> _authObsContext([Map<String, Object?>? extra]) {
    return <String, Object?>{
      'uid': currentUser?['uid'],
      'accountId': currentUser?['accountId'],
      'role': currentUser?['role'],
      'isOffline': _offlineSession,
      if (deviceId != null && deviceId!.isNotEmpty) 'deviceId': deviceId,
      ...?extra,
    };
  }

  void _authObsWarn(
    String code,
    String message, {
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    AppObservability.warn(
      scope: 'AUTH',
      code: code,
      message: message,
      flowId: flowId,
      context: _authObsContext(context),
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _authObsError(
    String code,
    String message, {
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    AppObservability.error(
      scope: 'AUTH',
      code: code,
      message: message,
      flowId: flowId,
      context: _authObsContext(context),
      error: error,
      stackTrace: stackTrace,
    );
  }

  String? get pendingWipeAccountId => _pendingWipeAccountId;

  Future<void> _applyPendingLocalWipeState({
    required String reason,
    String? accountId,
    bool notify = true,
  }) async {
    final normalized = accountId?.trim();
    final targetAccountId =
        (normalized == null || normalized.isEmpty) ? null : normalized;
    await ActiveAccountStore.setPendingWipe(targetAccountId);
    _pendingLocalWipe = true;
    _pendingWipeAccountId = targetAccountId;
    _resetPermissionsInMemory();
    _lastBackfilledSyncAccountId = null;
    await _suspendAccountBoundRuntimeForIsolation(reason: reason);
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _suspendAccountBoundRuntimeForIsolation({
    required String reason,
  }) async {
    await _stopDoctorPatientAlerts();
    await _stopPlanRealtime();
    try {
      await PushNotificationsService.instance.dispose();
    } catch (e, st) {
      _authObsWarn(
        ObsCode.authSignOutPushDisposeFailed,
        'push notification dispose failed while entering isolation mode',
        flowId: _newAuthFlow('isolation_push_dispose'),
        context: {
          'reason': reason,
        },
        error: e,
        stackTrace: st,
      );
    }
    try {
      await pauseSync();
    } catch (e, st) {
      _authObsWarn(
        ObsCode.authPauseSyncFailed,
        'pauseSync failed while entering isolation mode',
        flowId: _newAuthFlow('isolation_pause_sync'),
        context: {
          'reason': reason,
        },
        error: e,
        stackTrace: st,
      );
    }
    try {
      await _auth.suspendRuntimeBindings();
    } catch (e, st) {
      _authObsWarn(
        ObsCode.authBootstrapSyncFailed,
        'runtime suspension failed while entering isolation mode',
        flowId: _newAuthFlow('isolation_suspend_runtime'),
        context: {
          'reason': reason,
        },
        error: e,
        stackTrace: st,
      );
    }
  }

  AuthProvider({NhostAuthService? authService, bool listenAuthChanges = true})
      : _auth = authService ?? NhostAuthService() {
    if (listenAuthChanges) {
      // الاستماع لتغيّرات المصادقة
      _authSub = _auth.authStateChanges.listen((event) async {
        if (event == AuthenticationState.signedOut) {
          // هذه الإشارة تأتي بعد signOut — نظّف الحالة المحلية فقط.
          currentUser = null;
          _resetPermissionsInMemory();
          clearOwnerOnboardingState();
          AuthRoleState.clear();
          _lastGuardOk = false;
          _lastGuardOkAt = null;
          _lastBackfilledSyncAccountId = null;
          _sessionReconcileInFlight = null;
          NhostGraphqlService.refreshClient();
          await _stopDoctorPatientAlerts();
          await _stopPlanRealtime();
          await PushNotificationsService.instance.dispose();
          await ActiveAccountStore.clearPendingWipe();
          _pendingLocalWipe = false;
          _pendingWipeAccountId = null;
          await _clearStorage();
          notifyListeners();
          return;
        }

        if (_authFlowRunning) {
          _authDiagWarn('_authFlow:reentrySkip', context: {
            'event': event.name,
          });
          return;
        }
        _authFlowRunning = true;
        try {
          // لأي حدث آخر: نحدّث من الشبكة عند الدخول أو عند حلول موعد الفحص
          final due = await _isNetCheckDue();
          if (event == AuthenticationState.signedIn) {
            // Reset role header before any post-login GraphQL requests.
            AuthRoleState.clear();
            NhostGraphqlService.refreshClient();
            await _networkRefreshAndMark();
          } else if (due) {
            await _networkRefreshAndMark();
          } else {
            await _loadFromStorage();
            // إن كان accountId مفقودًا من التخزين، حاول حسمه سريعًا من الشبكة
            if ((currentUser?['accountId'] ?? '').toString().isEmpty) {
              try {
                final acc = await _auth.resolveAccountId();
                if (acc != null && acc.isNotEmpty) {
                  currentUser ??= {};
                  currentUser!['accountId'] = acc;
                  await _persistUser();
                }
              } catch (e, st) {
                _authObsWarn(
                  ObsCode.authResolveAccountIdFailed,
                  'resolveAccountId failed during auth flow reconciliation',
                  flowId: _newAuthFlow('auth_state_resolve_account'),
                  context: {
                    'source': 'auth_state_listener',
                  },
                  error: e,
                  stackTrace: st,
                );
              }
            }
          }

          // تحقّق من الحساب الفعّال (غير مجمّد/غير معطّل)
          final guard = await _ensureActiveAccountOrSignOut();
          if (isDisabled) {
            await signOut();
            return;
          }
          if (guard != AuthAccountGuardResult.ok) {
            // لا نفعّل مزامنة أو صلاحيات إذا الحساب غير صالح أو الشبكة متذبذبة
            notifyListeners();
            return;
          }

          if (requiresLocalIsolationWipe) {
            await _suspendAccountBoundRuntimeForIsolation(
              reason: 'auth_state_listener',
            );
            notifyListeners();
            return;
          }

          // تأكيد deviceId
          await _ensureDeviceId();

          // جلب صلاحيات الميزات + CRUD للحساب الحالي (إن وُجد)
          if (accountId != null && accountId!.isNotEmpty && !isSuperAdmin) {
            await _refreshFeaturePermissions();
          }

          // Bootstrap للمزامنة/Realtime عبر الخدمة (idempotent نسبيًا)
          if (isLoggedIn) {
            unawaited(bootstrapSync());
          }

          notifyListeners();
        } finally {
          _authFlowRunning = false;
        }
      });
    }
  }

  /// نادِها في main() بعد تهيئة Nhost.
  Future<void> init() {
    final inFlight = _initInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _initInternal();
    _initInFlight = future;
    return future;
  }

  Future<void> _initInternal() async {
    _initComplete = false;
    _initError = null;
    notifyListeners();
    final user = _auth.currentUser;
    try {
      if (user != null) {
        final due = await _isNetCheckDue();
        if (due) {
          await _networkRefreshAndMark();
        } else {
          await _loadFromStorage();
          // تأكيد accountId إن كان مفقودًا
          if ((currentUser?['accountId'] ?? '').toString().isEmpty) {
            try {
              final acc = await _auth.resolveAccountId();
              if (acc != null && acc.isNotEmpty) {
                currentUser ??= {};
                currentUser!['accountId'] = acc;
                await _persistUser();
              }
            } catch (e, st) {
              _authObsWarn(
                ObsCode.authResolveAccountIdFailed,
                'resolveAccountId failed during init reconciliation',
                flowId: _newAuthFlow('init_resolve_account'),
                context: {
                  'source': 'init',
                },
                error: e,
                stackTrace: st,
              );
            }
          }
        }
      } else {
        await _loadFromStorage();
        if (currentUser != null) {
          // نحاول استعادة جلسة Nhost إن كانت موجودة في التخزين الآمن.
          final restored =
              await _tryRestoreNhostSessionIfNeeded(reason: 'init');
          if (restored) {
            _offlineSession = false;
            await _networkRefreshAndMark();
          } else if (_auth.currentUser == null) {
            _offlineSession = true;
          }
        } else {
          // لا يوجد مستخدم على Nhost ولا بيانات محلية.
          currentUser = null;
          _resetPermissionsInMemory();
          await _clearStorage();
        }
      }

      if (isLoggedIn) {
        // تأكيد الحساب الفعّال
        await _ensureActiveAccountOrSignOut();

        if (requiresLocalIsolationWipe) {
          await _suspendAccountBoundRuntimeForIsolation(reason: 'init');
          _startNetworkMonitor();
          return;
        }

        await _ensureDeviceId();

        // تحميل الصلاحيات من التخزين (إن وُجدت) ثم محاولة تحديثها من الشبكة
        await _loadPermissionsFromStorage();
        if (accountId != null &&
            accountId!.isNotEmpty &&
            !isSuperAdmin &&
            _auth.currentUser != null) {
          unawaited(_refreshFeaturePermissions());
        }

        if (!_offlineSession) {
          unawaited(bootstrapSync());
        }
      }

      _startNetworkMonitor();
    } catch (e, st) {
      _initError = e;
      _authObsError(
        ObsCode.authProviderInitFailed,
        'AuthProvider.init failed',
        flowId: _newAuthFlow('provider_init'),
        error: e,
        stackTrace: st,
      );
      rethrow;
    } finally {
      _initComplete = true;
      _initInFlight = null;
      notifyListeners();
    }
  }

  void _startNetworkMonitor() {
    _netSub?.cancel();
    unawaited(NetworkStatusService.instance.start());
    _netSub = NetworkStatusService.instance.changes.listen((online) async {
      if (!isLoggedIn) return;
      if (!online) {
        _offlineSession = true;
        try {
          await pauseSync();
        } catch (e, st) {
          _authObsWarn(
            ObsCode.authPauseSyncFailed,
            'pauseSync failed after network disconnect',
            flowId: _newAuthFlow('network_offline'),
            context: {
              'online': online,
            },
            error: e,
            stackTrace: st,
          );
        }
        return;
      }
      final now = DateTime.now();
      if (_lastOnlineSyncAt != null &&
          now.difference(_lastOnlineSyncAt!).inSeconds < 20) {
        return;
      }
      _lastOnlineSyncAt = now;
      try {
        final wasOffline = _offlineSession;
        final result = await reconcileAuthenticatedSession(
          reason: 'netBackOnline',
          bootstrapOnSuccess: true,
          bootstrapPull: true,
          resumeSyncOnSuccess: true,
        );
        if (result.isSuccess) {
          if (wasOffline) {
            AppErrorReporter.info('تم استعادة الاتصال وتمت المزامنة بنجاح');
          }
          _offlineSession = false;
        }
      } catch (e, st) {
        _authObsWarn(
          ObsCode.authNetworkMonitorFailed,
          'network monitor refresh flow failed',
          flowId: _newAuthFlow('network_monitor'),
          context: {
            'online': online,
          },
          error: e,
          stackTrace: st,
        );
      }
    });
  }

  /// يحصّل ويخزّن معرّف الجهاز الدائم
  Future<void> _ensureDeviceId() async {
    if (deviceId != null && deviceId!.isNotEmpty) return;
    final id = await DeviceIdService.getId();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kDeviceId, id);
    deviceId = id;
  }

  /*──────── Actions ────────*/

  Future<AuthResponse> signIn(String email, String password) {
    return _auth.signInWithEmailPassword(
      email: email,
      password: password,
    );
  }

  Future<AuthResponse> signUp(
    String email,
    String password, {
    String? locale,
  }) {
    return _auth.signUpWithEmailPassword(
      email: email,
      password: password,
      locale: locale,
    );
  }

  Future<String> selfCreateAccount(ClinicProfileInput profile) async {
    final accountId = await _auth.selfCreateAccount(profile: profile);
    if (accountId.trim().isEmpty) {
      throw StateError('self_create_account returned empty account id');
    }
    return accountId;
  }

  Future<void> updateClinicProfile(ClinicProfileInput profile) {
    return _auth.updateClinicProfile(profile: profile);
  }

  Future<void> signOut() async {
    try {
      await PushNotificationsService.instance.deactivateCurrentToken();
    } catch (e, st) {
      _authObsWarn(
        ObsCode.authSignOutPushDeactivateFailed,
        'deactivateCurrentToken failed during signOut',
        flowId: _newAuthFlow('sign_out'),
        error: e,
        stackTrace: st,
      );
    }

    try {
      await _auth.signOut(); // يوقف المزامنة/الحراسة داخليًا
    } catch (e, st) {
      _authObsWarn(
        ObsCode.authSignOutRemoteFailed,
        'remote signOut failed',
        flowId: _newAuthFlow('sign_out'),
        error: e,
        stackTrace: st,
      );
    }

    try {
      await PushNotificationsService.instance.dispose();
    } catch (e, st) {
      _authObsWarn(
        ObsCode.authSignOutPushDisposeFailed,
        'push notification dispose failed during signOut',
        flowId: _newAuthFlow('sign_out'),
        error: e,
        stackTrace: st,
      );
    }

    currentUser = null;
    AuthRoleState.clear();
    NhostGraphqlService.refreshClient();
    _resetPermissionsInMemory();
    clearOwnerOnboardingState();
    _lastGuardOk = false;
    _lastGuardOkAt = null;
    _lastBackfilledSyncAccountId = null;
    _sessionReconcileInFlight = null;

    final sp = await SharedPreferences.getInstance();
    await _clearStorage();
    await sp.remove(_kLastNetCheckAt);
    await ActiveAccountStore.clearPendingWipe();
    _pendingLocalWipe = false;
    _pendingWipeAccountId = null;
    await _stopPlanRealtime();

    notifyListeners();
  }

  /// يجري تحديثًا كاملاً من الشبكة ثم يتحقق من صلاحية الحساب الحالي.
  Future<AuthSessionResult> refreshAndValidateCurrentUser() async {
    try {
      final refreshed = await _networkRefreshAndMark();
      final guard = await _ensureActiveAccountOrSignOut();

      switch (guard) {
        case AuthAccountGuardResult.ok:
          // في حال كان التوكن يشير إلى سوبر أدمن ولم تُحدّث الحالة بعد
          if (!isSuperAdmin) {
            final nhostUser = _auth.currentUser;
            final roles = nhostUser?.roles ?? const <String>[];
            final isSuper = roles.any(
                  (r) => r.toLowerCase() == 'superadmin',
                ) ||
                (nhostUser?.defaultRole ?? '').toLowerCase() == 'superadmin';
            if (isSuper) {
              currentUser ??= {};
              currentUser!['uid'] = nhostUser?.id ?? currentUser?['uid'];
              currentUser!['email'] = nhostUser?.email ?? currentUser?['email'];
              currentUser!['role'] = 'superadmin';
              currentUser!['isSuperAdmin'] = true;
              currentUser!['accountId'] = null;
              AuthRoleState.setSuperAdmin(true);
              await _persistUser();
            }
          }
          if (!isSuperAdmin) {
            final accId = accountId;
            if (accId == null || accId.isEmpty) {
              return refreshed
                  ? const AuthSessionResult.noAccount()
                  : const AuthSessionResult.networkError();
            }
          }
          await _refreshClinicProfileCache();
          await _ensurePlanRealtime();
          notifyListeners();
          return const AuthSessionResult.success();
        case AuthAccountGuardResult.accountFrozen:
          return const AuthSessionResult.accountFrozen();
        case AuthAccountGuardResult.disabled:
          return const AuthSessionResult.disabled();
        case AuthAccountGuardResult.noAccount:
          return const AuthSessionResult.noAccount();
        case AuthAccountGuardResult.planUpgradeRequired:
          return const AuthSessionResult.planUpgradeRequired();
        case AuthAccountGuardResult.signedOut:
          return const AuthSessionResult.signedOut();
        case AuthAccountGuardResult.transientFailure:
          return const AuthSessionResult.networkError();
        case AuthAccountGuardResult.unknown:
          return const AuthSessionResult.unknown();
      }
    } catch (e, st) {
      dev.log('refreshAndValidateCurrentUser failed', error: e, stackTrace: st);
      return AuthSessionResult.unknown(error: e, stackTrace: st);
    }
  }

  Future<void> _ensurePlanRealtime() async {
    final uid = currentUser?['uid']?.toString() ?? '';
    if (uid.isEmpty || isSuperAdmin) return;
    if (_planSubUid == uid && _planSub != null) return;
    await _stopPlanRealtime();
    _planSubUid = uid;

    const doc = r'''
      subscription PlanWatch($uid: uuid!) {
        account_users(where: {user_uid: {_eq: $uid}}) {
          plan_code
          plan_end_at
          chat_code
        }
      }
    ''';

    _planSub = NhostGraphqlService.client
        .subscribe(
      SubscriptionOptions(
        document: gql(doc),
        variables: {'uid': uid},
      ),
    )
        .listen((result) async {
      if (result.hasException) return;
      final rows = result.data?['account_users'] as List?;
      if (rows == null || rows.isEmpty) return;
      final row = rows.first as Map;
      final planCode = (row['plan_code'] ?? 'free').toString().toLowerCase();
      final planEndAt = _readPlanEndAt(row['plan_end_at']);
      final chatCode = row['chat_code']?.toString().trim() ?? '';

      var changed = false;
      final currentPlan =
          (currentUser?['planCode'] ?? 'free').toString().toLowerCase();
      if (currentPlan != planCode) {
        currentUser ??= {};
        currentUser!['planCode'] = planCode;
        changed = true;
      }
      final currentEnd = _readPlanEndAt(currentUser?['planEndAt']);
      if ((currentEnd?.toIso8601String() ?? '') !=
          (planEndAt?.toIso8601String() ?? '')) {
        currentUser ??= {};
        currentUser!['planEndAt'] = planEndAt;
        changed = true;
      }
      if (chatCode.isNotEmpty) {
        final currentChat = (currentUser?['chatCode'] ?? '').toString();
        if (currentChat != chatCode) {
          currentUser ??= {};
          currentUser!['chatCode'] = chatCode;
          changed = true;
        }
      } else if ((currentUser?['chatCode'] ?? '').toString().isNotEmpty) {
        currentUser ??= {};
        currentUser!.remove('chatCode');
        changed = true;
      }

      if (changed) {
        await _persistUser();
        notifyListeners();
      }
    });
  }

  Future<void> _stopPlanRealtime() async {
    await _planSub?.cancel();
    _planSub = null;
    _planSubUid = null;
  }

  /// تغيير سياق الحساب (مثلاً المالك يبدّل بين عيادات)
  Future<void> setAccountContext(String newAccountId) async {
    if (currentUser == null) return;
    final normalized = newAccountId.trim();
    if (normalized.isEmpty) return;
    currentUser!['accountId'] = normalized;
    await _persistUser();
    final hasForeignRows =
        await DBService.instance.hasRowsForOtherAccount(normalized);
    if (hasForeignRows) {
      await _applyPendingLocalWipeState(
        reason: 'setAccountContext',
        accountId: normalized,
      );
      return;
    }

    await ActiveAccountStore.clearPendingWipe();
    _pendingLocalWipe = false;
    _pendingWipeAccountId = null;

    await _refreshFeaturePermissions();
    await _refreshClinicProfileCache();
    await bootstrapSync(
      pull: true,
      realtime: true,
      enableLogs: true,
      wipeLocalFirst: false,
    );
    notifyListeners();
  }

  Future<void> refreshPendingLocalWipeState() async {
    _pendingLocalWipe = await ActiveAccountStore.hasPendingWipe();
    _pendingWipeAccountId = await ActiveAccountStore.readPendingWipeAccountId();
    if (_pendingLocalWipe) {
      await _suspendAccountBoundRuntimeForIsolation(
        reason: 'refreshPendingLocalWipeState',
      );
      _resetPermissionsInMemory();
    }
    notifyListeners();
  }

  Future<bool> performPendingLocalWipe({
    bool createBackup = true,
    bool rebootstrap = true,
  }) async {
    if (!_pendingLocalWipe) return true;
    try {
      await _suspendAccountBoundRuntimeForIsolation(
          reason: 'performPendingWipe');
      if (createBackup) {
        await BackupRestoreService.backupDatabase(
          storageType: StorageType.local,
          includeSharedPrefs: true,
        );
      }
      await DBService.instance.clearAllLocalTables();
      await ChatLocalStore.instance.clearAllData();
      try {
        await AttachmentCache.instance.purgeAll();
      } catch (e, st) {
        _authObsWarn(
          ObsCode.authPendingWipeAttachmentPurgeFailed,
          'attachment cache purge failed during pending local wipe',
          flowId: _newAuthFlow('pending_wipe'),
          context: {
            'createBackup': createBackup,
            'rebootstrap': rebootstrap,
          },
          error: e,
          stackTrace: st,
        );
      }
      await ActiveAccountStore.clearPendingWipe();
      _pendingLocalWipe = false;
      _pendingWipeAccountId = null;
      if (hasAccountContext) {
        await ActiveAccountStore.writeAccountId(accountId);
      }
      _resetPermissionsInMemory();
      if (rebootstrap) {
        if (hasAccountContext && !isSuperAdmin) {
          await _refreshFeaturePermissions();
        }
        await bootstrapSync(
          pull: true,
          realtime: true,
          enableLogs: true,
        );
      }
      notifyListeners();
      return true;
    } catch (e, st) {
      dev.log('performPendingLocalWipe failed', error: e, stackTrace: st);
      return false;
    }
  }

  /// تحديث يدوي للصلاحيات (مفيد بعد تغيير إعدادات المالك)
  Future<void> refreshPermissions() => _refreshFeaturePermissions();

  /// أدوات مساعدة اختيارية: تغيير كلمة مرور/إعادة تعيين/تحديث جلسة
  Future<void> changePassword(String newPassword) =>
      _auth.changePassword(newPassword);
  Future<void> requestPasswordReset(String email, {String? redirectTo}) =>
      _auth.requestPasswordReset(email, redirectTo: redirectTo);
  Future<void> refreshSession() => _auth.refreshSession();

  Future<AuthSessionResult> reconcileAuthenticatedSession({
    String reason = 'guard',
    bool bootstrapOnSuccess = false,
    bool bootstrapPull = false,
    bool resumeSyncOnSuccess = false,
  }) async {
    if (!hasLocalSession) {
      return const AuthSessionResult.signedOut();
    }
    if (_sessionReconcileInFlight != null) {
      return _sessionReconcileInFlight!;
    }

    final future = _reconcileAuthenticatedSessionInternal(
      reason: reason,
      bootstrapOnSuccess: bootstrapOnSuccess,
      bootstrapPull: bootstrapPull,
      resumeSyncOnSuccess: resumeSyncOnSuccess,
    );
    _sessionReconcileInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_sessionReconcileInFlight, future)) {
        _sessionReconcileInFlight = null;
      }
    }
  }

  /*──────── Internals ────────*/

  @visibleForTesting
  void debugSetCurrentUser(Map<String, dynamic>? user) {
    currentUser = user;
  }

  @visibleForTesting
  void debugSetPermissions({
    required Set<String> allowed,
    required bool canCreate,
    required bool canUpdate,
    required bool canDelete,
    required bool loaded,
    String? error,
  }) {
    _allowedFeatures = allowed;
    _canCreate = canCreate;
    _canUpdate = canUpdate;
    _canDelete = canDelete;
    _permissionsLoaded = loaded;
    _permissionsError = error;
  }

  @visibleForTesting
  void debugSetPendingLocalWipe({
    required bool pending,
    String? accountId,
  }) {
    _pendingLocalWipe = pending;
    final normalized = accountId?.trim();
    _pendingWipeAccountId =
        normalized == null || normalized.isEmpty ? null : normalized;
  }

  @visibleForTesting
  void debugSetHasNhostSession(bool? value) {
    _debugHasNhostSessionOverride = value;
  }

  Future<bool> _networkRefreshAndMark() async {
    if (_refreshInFlight != null) {
      return _refreshInFlight!;
    }
    final now = DateTime.now();
    if (_lastRefreshAttemptAt != null &&
        now.difference(_lastRefreshAttemptAt!).inSeconds < 2) {
      return _lastRefreshSuccess;
    }
    _lastRefreshAttemptAt = now;
    final future = _networkRefreshAndMarkInternal();
    _refreshInFlight = future;
    final result = await future;
    _refreshInFlight = null;
    _lastRefreshSuccess = result;
    return result;
  }

  Future<bool> _networkRefreshAndMarkInternal() async {
    final startCtx = <String, Object?>{
      'uid': currentUser?['uid'],
      'hasAccount': ((currentUser?['accountId'] ?? '').toString().isNotEmpty),
    };
    _authDiag('_networkRefreshAndMark:start', context: startCtx);
    bool success = false;
    try {
      var nhostUser = _auth.currentUser;
      if (nhostUser == null && currentUser != null) {
        final restored = await _tryRestoreNhostSessionIfNeeded(
          reason: 'networkRefresh',
        );
        nhostUser = _auth.currentUser;
        if (restored && nhostUser != null) {
          _offlineSession = false;
        }
      }
      if (nhostUser == null && currentUser != null) {
        // لا تمسح الجلسة المحلية إذا كانت جلسة Nhost غير متاحة حالياً.
        // تعامل معها كجلسة Offline مؤقتة.
        _offlineSession = true;
        _authDiagWarn('_networkRefreshAndMark:missingAuthSession', context: {
          'uid': currentUser?['uid'],
          'accountId': currentUser?['accountId'],
        });
        await _persistUser();
        return false;
      }
      _authDiag('_networkRefreshAndMark:refreshUser');
      await _refreshUser(); // يجلب من RPCs/fallbacks
      _authDiag(
        '_networkRefreshAndMark:afterRefresh',
        context: {
          'uid': currentUser?['uid'],
          'accountId': currentUser?['accountId'],
          'role': currentUser?['role'],
        },
      );
      if ((currentUser?['accountId'] ?? '').toString().isEmpty) {
        try {
          final acc = await _auth.resolveAccountId();
          if (acc != null && acc.isNotEmpty) {
            currentUser ??= {};
            currentUser!['accountId'] = acc;
            _authDiag(
              '_networkRefreshAndMark:resolvedAccountId',
              context: {'source': 'resolveAccountId', 'accountId': acc},
            );
          }
        } catch (e, st) {
          _authObsWarn(
            ObsCode.authResolveAccountIdFailed,
            'resolveAccountId failed during network refresh',
            flowId: _newAuthFlow('network_refresh_resolve_account'),
            error: e,
            stackTrace: st,
          );
        }
      }

      if (((currentUser?['accountId'] ?? '').toString().isEmpty) ||
          ((currentUser?['role'] ?? '').toString().isEmpty)) {
        if (isSuperAdmin) {
          _authDiag(
            '_networkRefreshAndMark:superAdminSkipActiveAccount',
            context: {'uid': currentUser?['uid']},
          );
          success = true;
          return true;
        }
        // لا نستدعي resolveActiveAccountOrThrow هنا لتجنّب تكرار الشبكة.
        // التحقق الفعلي سيتم في _ensureActiveAccountOrSignOut (مرة واحدة).
      }

      success = ((currentUser?['accountId'] ?? '').toString().isNotEmpty);
    } catch (e, st) {
      dev.log('_networkRefreshAndMark failed', error: e, stackTrace: st);
      _authDiagError(
        '_networkRefreshAndMark:error',
        context: {
          'uid': currentUser?['uid'],
          'accountId': currentUser?['accountId'],
        },
        error: e,
        stackTrace: st,
      );
      if (_isTransientNetworkError(e)) {
        _offlineSession = true;
      }
    }

    await _persistUser();
    _authDiag('_networkRefreshAndMark:persisted', context: {
      'uid': currentUser?['uid'],
      'accountId': currentUser?['accountId'],
      'success': success,
    });

    if (success) {
      _offlineSession = false;
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kLastNetCheckAt, DateTime.now().toIso8601String());
      _authDiag('_networkRefreshAndMark:success', context: {
        'accountId': currentUser?['accountId'],
        'role': currentUser?['role'],
      });
    } else {
      _authDiagWarn('_networkRefreshAndMark:missingAccountId', context: {
        'uid': currentUser?['uid'],
      });
    }
    return success;
  }

  Future<AuthSessionResult> _reconcileAuthenticatedSessionInternal({
    required String reason,
    required bool bootstrapOnSuccess,
    required bool bootstrapPull,
    required bool resumeSyncOnSuccess,
  }) async {
    _authDiag('_reconcileAuthenticatedSession:start', context: {
      'reason': reason,
      'topology': sessionTopologyState,
      'bootstrapOnSuccess': bootstrapOnSuccess,
      'bootstrapPull': bootstrapPull,
      'resumeSyncOnSuccess': resumeSyncOnSuccess,
    });

    if (!hasLocalSession) {
      return const AuthSessionResult.signedOut();
    }

    if (requiresLocalIsolationWipe) {
      await _suspendAccountBoundRuntimeForIsolation(reason: reason);
      _authDiagWarn('_reconcileAuthenticatedSession:isolationRequired',
          context: {
            'reason': reason,
            'pendingWipeAccountId': _pendingWipeAccountId,
          });
      return const AuthSessionResult.isolationRequired();
    }

    if (!hasNhostSession) {
      final restored = await ensureNhostSessionReady(reason: reason);
      if (!restored && !hasNhostSession) {
        if (!hasLocalSession) {
          return const AuthSessionResult.signedOut();
        }
        _offlineSession = true;
        notifyListeners();
        _authDiagWarn('_reconcileAuthenticatedSession:remoteMissing', context: {
          'reason': reason,
          'topology': sessionTopologyState,
        });
        return const AuthSessionResult.networkError();
      }
    }

    final result = await refreshAndValidateCurrentUser();
    if (!result.isSuccess) {
      _authDiagWarn('_reconcileAuthenticatedSession:nonSuccess', context: {
        'reason': reason,
        'status': result.status.name,
        'topology': sessionTopologyState,
      });
      return result;
    }

    if (requiresLocalIsolationWipe) {
      await _suspendAccountBoundRuntimeForIsolation(reason: reason);
      return const AuthSessionResult.isolationRequired();
    }

    if (resumeSyncOnSuccess && !isSuperAdmin) {
      try {
        await resumeSync();
      } catch (e, st) {
        _authObsWarn(
          ObsCode.authResumeSyncFailed,
          'resumeSync failed during authenticated session reconciliation',
          flowId: _newAuthFlow('reconcile_resume_sync'),
          context: {
            'reason': reason,
          },
          error: e,
          stackTrace: st,
        );
      }
    }

    if (bootstrapOnSuccess && canEnterClinicShell) {
      await bootstrapSync(
        pull: bootstrapPull,
        realtime: true,
        enableLogs: kDebugMode,
        debounce: const Duration(seconds: 1),
      );
    }

    _authDiag('_reconcileAuthenticatedSession:ok', context: {
      'reason': reason,
      'topology': sessionTopologyState,
    });
    return result;
  }

  bool _isTransientNetworkError(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    if (error is OperationException) {
      if (error.linkException != null) return true;
      final msg = error.toString().toLowerCase();
      if (msg.contains('socket') ||
          msg.contains('failed host lookup') ||
          msg.contains('connection') ||
          msg.contains('handshake') ||
          msg.contains('timeout') ||
          msg.contains('503') ||
          msg.contains('502')) {
        return true;
      }
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('timeout') ||
        msg.contains('timed out') ||
        msg.contains('failed host lookup') ||
        msg.contains('socketexception') ||
        msg.contains('connection') ||
        msg.contains('network') ||
        msg.contains('503') ||
        msg.contains('502') ||
        msg.contains('semaphore');
  }

  Future<bool> _isNetCheckDue() async {
    final sp = await SharedPreferences.getInstance();
    final iso = sp.getString(_kLastNetCheckAt);
    if (iso == null) return true;
    final last = DateTime.tryParse(iso);
    if (last == null) return true;
    return DateTime.now().difference(last).inMinutes >=
        _kNetCheckIntervalMinutes;
  }

  /// يجلب بيانات المستخدم من السيرفر مع حسم accountId مؤكد عبر عدة fallbacks
  Future<void> _refreshUser() async {
    final u = _auth.currentUser;
    if (u == null) {
      currentUser = null;
      _resetPermissionsInMemory();
      return;
    }

    final prevAccountId = currentUser?['accountId']?.toString();
    final prevChatCode = currentUser?['chatCode']?.toString().trim();
    final prevIsSuper = currentUser?['isSuperAdmin'] == true;
    Map<String, dynamic>? info;
    try {
      info = await _auth
          .fetchCurrentUser(); // { uid,email,accountId,role,isSuperAdmin }
    } catch (e, st) {
      _authObsWarn(
        ObsCode.authRefreshFetchUserFailed,
        'fetchCurrentUser failed during refresh',
        flowId: _newAuthFlow('refresh_user'),
        error: e,
        stackTrace: st,
      );
      info = null;
    }

    // accountId مبدئيًا من info
    String? accId = info?['accountId'] as String?;
    final infoDisabled = info?['disabled'] == true;

    // Fallbacks لحسم accountId
    if (accId == null || accId.isEmpty) {
      try {
        accId = await _auth.resolveAccountId();
      } catch (e, st) {
        _authObsWarn(
          ObsCode.authResolveAccountIdFailed,
          'resolveAccountId failed during user refresh fallback',
          flowId: _newAuthFlow('refresh_user_resolve_account'),
          error: e,
          stackTrace: st,
        );
      }
    }
    // لا نستدعي resolveActiveAccountOrThrow هنا لتجنب تكرار الشبكة.

    // الدور والبريد — توحيد role = 'superadmin' إن كان سوبر
    final infoRole = (info?['role'] as String?)?.toLowerCase();
    final infoIsSuper = info?['isSuperAdmin'] == true;
    final infoPlan = (info?['planCode'] as String?)?.toLowerCase();
    final infoPlanEndAt = _readPlanEndAt(info?['planEndAt']);
    final infoChatCode = (info?['chatCode'] as String?)?.trim();
    final prevPlanEndAt = _readPlanEndAt(currentUser?['planEndAt']);
    if ((accId == null || accId.isEmpty) &&
        info == null &&
        prevAccountId != null &&
        prevAccountId.trim().isNotEmpty) {
      accId = prevAccountId.trim();
    }
    var effectiveChatCode = infoChatCode;
    if ((effectiveChatCode == null || effectiveChatCode.isEmpty) &&
        info == null &&
        prevChatCode != null &&
        prevChatCode.isNotEmpty) {
      effectiveChatCode = prevChatCode;
    }
    final role = infoIsSuper ? 'superadmin' : (infoRole ?? 'employee');
    final isSuper = infoIsSuper;

    currentUser = {
      'uid': u.id,
      'email': u.email ?? info?['email'],
      'accountId': accId, // ← المهم
      'role': role,
      'disabled': infoDisabled,
      'isSuperAdmin': isSuper,
      'planCode': infoPlan ?? 'free',
      'planEndAt': infoPlanEndAt ?? prevPlanEndAt,
      if (effectiveChatCode != null && effectiveChatCode.isNotEmpty)
        'chatCode': effectiveChatCode,
      if (deviceId != null) _kDeviceId: deviceId,
    };

    AuthRoleState.setSuperAdmin(isSuper);
    if (prevIsSuper != isSuper) {
      NhostGraphqlService.refreshClient();
    }

    if (!isSuper && accId != null && accId.isNotEmpty) {
      if (prevAccountId != accId) {
        await _auth.syncCurrentAccount(accId);
      }
    }
  }

  /// يتأكد أن الحساب الفعّال قابل للكتابة (غير مجمّد/غير معطّل) وإلا يخرج.
  Future<AuthAccountGuardResult> _ensureActiveAccountOrSignOut() async {
    if (_guardInFlight != null) {
      return _guardInFlight!;
    }
    final future = _ensureActiveAccountOrSignOutInternal();
    _guardInFlight = future;
    final result = await future;
    _guardInFlight = null;
    return result;
  }

  Future<AuthAccountGuardResult> _ensureActiveAccountOrSignOutInternal() async {
    if (!isLoggedIn) {
      _authDiag('_ensureActiveAccountOrSignOut:signedOutEarly');
      return AuthAccountGuardResult.signedOut;
    }
    if (_auth.currentUser == null && currentUser != null) {
      final restored = await _tryRestoreNhostSessionIfNeeded(
        reason: 'ensureActiveAccount',
      );
      if (restored && _auth.currentUser != null) {
        _offlineSession = false;
      } else {
        // الجلسة المحلية موجودة لكن جلسة Nhost غير متاحة — ابقِ المستخدم
        // ولا تفرض تسجيل خروج. سيتم التحقق عند رجوع الشبكة.
        _offlineSession = true;
        _authDiagWarn('_ensureActiveAccountOrSignOut:missingAuthSession',
            context: {
              'uid': uid,
              'accountId': accountId,
            });
        return AuthAccountGuardResult.transientFailure;
      }
    }
    if (isSuperAdmin) {
      _authDiag('_ensureActiveAccountOrSignOut:superAdminBypass', context: {
        'uid': uid,
      });
      _lastGuardOkAt = DateTime.now();
      _lastGuardOk = true;
      return AuthAccountGuardResult.ok; // السوبر أدمن خارج نطاق الحسابات
    }
    if (_isPlanExpired()) {
      _authDiagWarn('_ensureActiveAccountOrSignOut:planExpired', context: {
        'planCode': planCode,
        'planEndAt': planEndAt?.toIso8601String(),
      });
      _lastGuardOk = false;
      return AuthAccountGuardResult.planUpgradeRequired;
    }
    final now = DateTime.now();
    if (_lastGuardOk &&
        _lastGuardOkAt != null &&
        now.difference(_lastGuardOkAt!).inSeconds < 60 &&
        (accountId ?? '').isNotEmpty &&
        (role ?? '').isNotEmpty &&
        !isDisabled) {
      _authDiag('_ensureActiveAccountOrSignOut:cachedOk', context: {
        'accountId': accountId,
        'role': role,
      });
      return AuthAccountGuardResult.ok;
    }
    _authDiag('_ensureActiveAccountOrSignOut:start', context: {
      'uid': uid,
      'accountId': accountId,
    });
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        _authDiag('_ensureActiveAccountOrSignOut:attempt', context: {
          'attempt': attempt,
          'max': maxAttempts,
        });
        final aa = await _auth.resolveActiveAccountOrThrowFromCache(
          uid: uid ?? '',
          accountId: accountId,
          role: role,
          disabled: isDisabled,
          planCode: planCode,
        );
        currentUser ??= {};
        currentUser!['accountId'] = aa.id;
        currentUser!['role'] = aa.role.toLowerCase();
        currentUser!['disabled'] = false;
        await _persistUser();
        _authDiag('_ensureActiveAccountOrSignOut:ok', context: {
          'accountId': aa.id,
          'role': aa.role,
        });
        _lastGuardOkAt = DateTime.now();
        _lastGuardOk = true;
        return AuthAccountGuardResult.ok;
      } catch (e, st) {
        if (_isTransientNetworkError(e)) {
          final delay = Duration(milliseconds: 300 * (1 << (attempt - 1)));
          dev.log(
            'Transient error while validating active account (attempt $attempt/$maxAttempts): $e',
          );
          _authDiagWarn(
            '_ensureActiveAccountOrSignOut:transientError',
            context: {
              'attempt': attempt,
              'max': maxAttempts,
              'error': e.runtimeType.toString(),
            },
            stackTrace: st,
          );
          if (attempt >= maxAttempts) {
            dev.log(
                'Keeping session after transient failure to validate account.');
            _authDiagWarn('_ensureActiveAccountOrSignOut:transientGivingUp',
                context: {
                  'attempt': attempt,
                  'error': e.runtimeType.toString(),
                });
            return AuthAccountGuardResult.transientFailure;
          }
          await Future.delayed(delay);
          continue;
        }

        AuthAccountGuardResult result = AuthAccountGuardResult.disabled;
        if (e is AccountFrozenException) {
          result = AuthAccountGuardResult.accountFrozen;
        } else if (e is PlanUpgradeRequiredException) {
          result = AuthAccountGuardResult.planUpgradeRequired;
        } else if (e is AccountUserDisabledException) {
          result = AuthAccountGuardResult.disabled;
        } else if (e is StateError) {
          final lower = e.message.toLowerCase();
          if (lower.contains('not signed in') ||
              lower.contains('not authenticated')) {
            result = AuthAccountGuardResult.signedOut;
          }
          if (lower.contains('no active clinic') ||
              lower.contains('unable to resolve account')) {
            result = AuthAccountGuardResult.noAccount;
          }
        }

        dev.log('Active account invalid: $e', stackTrace: st);
        currentUser ??= {};
        if (result == AuthAccountGuardResult.signedOut) {
          _authDiagWarn(
            '_ensureActiveAccountOrSignOut:signedOut',
            context: {'attempt': attempt},
            stackTrace: st,
          );
          return result;
        }
        if (result == AuthAccountGuardResult.noAccount) {
          if (!_allowAutoCreateAccount) {
            _authDiagWarn(
              '_ensureActiveAccountOrSignOut:autoCreate:skipped',
              context: {'reason': 'auto-create disabled'},
              stackTrace: st,
            );
            currentUser!['disabled'] = false;
            currentUser!['accountId'] = null;
            await _persistUser();
            return result;
          }

          if (!_autoCreateAttempted) {
            _autoCreateAttempted = true;
            _allowAutoCreateAccount = false;
            final pendingProfile = _pendingClinicProfile;
            if (pendingProfile == null) {
              clearOwnerOnboardingState();
              _authDiagWarn(
                '_ensureActiveAccountOrSignOut:autoCreate:skipped',
                context: {'reason': 'missing clinic profile'},
                stackTrace: st,
              );
            } else {
              _authDiagWarn(
                '_ensureActiveAccountOrSignOut:autoCreate:attempt',
                context: {'seed': pendingProfile.nameAr},
                stackTrace: st,
              );
            }
            try {
              if (pendingProfile == null) {
                return result;
              }
              await selfCreateAccount(pendingProfile);
              clearOwnerOnboardingState();
              final aa = await _auth.resolveActiveAccountOrThrow();
              currentUser ??= {};
              currentUser!['accountId'] = aa.id;
              currentUser!['role'] = aa.role.toLowerCase();
              currentUser!['disabled'] = false;
              await _persistUser();
              _authDiag(
                '_ensureActiveAccountOrSignOut:autoCreate:ok',
                context: {'accountId': aa.id},
              );
              return AuthAccountGuardResult.ok;
            } catch (autoErr, autoSt) {
              dev.log(
                'Auto-create account failed: $autoErr',
                stackTrace: autoSt,
              );
              _authDiagWarn(
                '_ensureActiveAccountOrSignOut:autoCreate:failed',
                context: {'error': autoErr.runtimeType.toString()},
                stackTrace: autoSt,
              );
            }
          }
          // Keep session for onboarding (self_create_account flow).
          currentUser!['disabled'] = false;
          currentUser!['accountId'] = null;
          await _persistUser();
          _authDiagWarn(
            '_ensureActiveAccountOrSignOut:noAccount',
            context: {
              'attempt': attempt,
            },
            stackTrace: st,
          );
          return result;
        }
        if (result == AuthAccountGuardResult.planUpgradeRequired) {
          currentUser!['disabled'] = false;
          await _persistUser();
          _authDiagWarn(
            '_ensureActiveAccountOrSignOut:planUpgradeRequired',
            context: {'attempt': attempt},
            stackTrace: st,
          );
          _lastGuardOk = false;
          return result;
        }
        currentUser!['disabled'] = true;
        await _persistUser();
        _authDiagError(
          '_ensureActiveAccountOrSignOut:failure',
          context: {
            'result': result.name,
            'attempt': attempt,
          },
          error: e,
          stackTrace: st,
        );
        _lastGuardOk = false;
        if (result == AuthAccountGuardResult.signedOut) {
          return result;
        }
        await signOut();
        return result;
      }
    }
    _authDiagWarn('_ensureActiveAccountOrSignOut:unknownOutcome', context: {
      'uid': uid,
    });
    return AuthAccountGuardResult.unknown;
  }

  Future<bool> ensureNhostSessionReady({String reason = 'guard'}) async {
    if (_auth.currentUser != null) return true;
    final restored = await _tryRestoreNhostSessionIfNeeded(reason: reason);
    final ok = restored && _auth.currentUser != null;
    if (ok) {
      notifyListeners();
    }
    return ok;
  }

  Future<bool> _tryRestoreNhostSessionIfNeeded({required String reason}) async {
    if (_auth.currentUser != null) return true;
    if (currentUser == null) return false;
    // حاول أولًا استعادة الجلسة من التخزين المحلي بدون اشتراط اتصال.
    try {
      await _auth.restoreSessionLocal();
      if (_auth.currentUser != null) {
        _authDiag('_restoreSession:ok', context: {'reason': '$reason/local'});
        return true;
      }
    } catch (e, st) {
      if (_isInvalidRefreshToken(e)) {
        await _forceSignOutFromInvalidToken();
        return false;
      }
      _authObsWarn(
        ObsCode.authSessionRestoreLocalFailed,
        'restoreSessionLocal failed during session restore',
        flowId: _newAuthFlow('restore_session_local'),
        context: {
          'reason': reason,
        },
        error: e,
        stackTrace: st,
      );
    }
    if (!NetworkStatusService.instance.isOnline) return false;
    final now = DateTime.now();
    if (_lastSessionRestoreAttemptAt != null &&
        now.difference(_lastSessionRestoreAttemptAt!).inSeconds < 20) {
      return false;
    }
    _lastSessionRestoreAttemptAt = now;
    try {
      await _auth.refreshSession();
    } catch (e, st) {
      if (_isInvalidRefreshToken(e)) {
        await _forceSignOutFromInvalidToken();
        return false;
      }
      _authDiagWarn('_restoreSession:failed',
          context: {
            'reason': reason,
            'error': e.runtimeType.toString(),
          },
          stackTrace: st);
    }
    if (_auth.currentUser != null) {
      _authDiag('_restoreSession:ok', context: {'reason': reason});
      return true;
    }
    return false;
  }

  bool _isInvalidRefreshToken(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('invalid-refresh-token') ||
        (msg.contains('refresh token') && msg.contains('401')) ||
        (msg.contains('invalid') &&
            msg.contains('refresh') &&
            msg.contains('401'));
  }

  Future<void> _forceSignOutFromInvalidToken() async {
    await signOut();
  }

  void setPendingClinicProfile(ClinicProfileInput? profile) {
    _pendingClinicProfile = profile;
    if (profile == null) {
      clearOwnerOnboardingState();
    }
  }

  void clearOwnerOnboardingState() {
    _pendingClinicProfile = null;
    _allowAutoCreateAccount = false;
    _autoCreateAttempted = false;
  }

  Future<void> _refreshClinicProfileCache() async {
    try {
      final accId = accountId;
      if (accId == null || accId.isEmpty) return;
      final data = await _auth.fetchClinicProfile(accountId: accId);
      if (data == null) return;
      final existing = await DBService.instance.getClinicProfile(accId);
      final profile = ClinicProfile(
        accountId: data['id']?.toString() ?? accId,
        nameAr: data['name']?.toString() ?? '',
        cityAr: data['city_ar']?.toString() ?? '',
        streetAr: data['street_ar']?.toString() ?? '',
        nearAr: data['near_ar']?.toString() ?? '',
        nameEn: data['clinic_name_en']?.toString() ?? '',
        cityEn: data['city_en']?.toString() ?? '',
        streetEn: data['street_en']?.toString() ?? '',
        nearEn: data['near_en']?.toString() ?? '',
        phone: data['phone']?.toString() ?? '',
        phone2: data['phone2']?.toString(),
        logoPath: existing?.logoPath,
      );
      await DBService.instance.saveClinicProfile(profile);
    } catch (e, st) {
      _authObsWarn(
        ObsCode.authRefreshClinicProfileFailed,
        'refreshClinicProfileCache failed',
        flowId: _newAuthFlow('refresh_clinic_profile'),
        error: e,
        stackTrace: st,
      );
    }
  }

  /// يسمح لمحاولة واحدة فقط لإنشاء حساب تلقائي (مسار onboarding المالك).
  void allowAutoCreateAccountOnce() {
    _allowAutoCreateAccount = true;
    _autoCreateAttempted = false;
  }

  /// يثبت صلاحية السوبر أدمن من التوكن (Fallback سريع لتجنّب مسار إنشاء الحساب).
  Future<void> markSuperAdminFromSession() async {
    final user = _auth.currentUser;
    if (user == null) return;
    currentUser ??= {};
    currentUser!['uid'] = user.id;
    currentUser!['email'] = user.email ?? currentUser?['email'];
    currentUser!['role'] = 'superadmin';
    currentUser!['isSuperAdmin'] = true;
    currentUser!['accountId'] = null;
    AuthRoleState.setSuperAdmin(true);
    await _persistUser();
  }

  FeaturePermissions _defaultPermissionsForRole() {
    final r = role?.toLowerCase();
    if (r == 'owner' || r == 'admin') {
      return FeaturePermissions.defaultsAllowAll();
    }
    return FeaturePermissions.defaultsDenyAll();
  }

  /// يجلب صلاحيات الميزات + CRUD للحساب الحالي ويخزّنها محليًا
  Future<void> _refreshFeaturePermissions() async {
    if (_auth.currentUser == null) return;
    final accId = accountId;
    if (accId == null || accId.isEmpty) return;
    try {
      final perms = await _auth.fetchMyFeaturePermissions(
        accountId: accId,
        fallback: _defaultPermissionsForRole(),
      );
      _allowAllFeatures = perms.allowAll;
      _allowedFeatures = perms.allowedFeatures;
      _canCreate = perms.canCreate;
      _canUpdate = perms.canUpdate;
      _canDelete = perms.canDelete;
      _permissionsLoaded = true;
      _permissionsError = null;
      await _persistPermissions();
    } catch (e, st) {
      dev.log('refreshFeaturePermissions failed', error: e, stackTrace: st);
      _authObsWarn(
        ObsCode.authRefreshPermissionsFailed,
        'refreshFeaturePermissions failed',
        flowId: _newAuthFlow('refresh_permissions'),
        error: e,
        stackTrace: st,
      );
      final fallback = e is FeaturePermissionsFetchException
          ? (e.fallback ?? _defaultPermissionsForRole())
          : _defaultPermissionsForRole();
      _permissionsLoaded = true;
      _permissionsError = '${e}';
      _allowAllFeatures = fallback.allowAll;
      _allowedFeatures = fallback.allowedFeatures;
      _canCreate = fallback.canCreate;
      _canUpdate = fallback.canUpdate;
      _canDelete = fallback.canDelete;
      await _persistPermissions();
    }
    notifyListeners();
  }

  void _resetPermissionsInMemory() {
    _allowAllFeatures = false;
    _allowedFeatures = <String>{};
    _canCreate = false;
    _canUpdate = false;
    _canDelete = false;
    _permissionsLoaded = false;
    _permissionsError = null;
  }

  Future<void> _persistPermissions() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kAllowAllFeatures, _allowAllFeatures);
    await sp.setString(_kAllowedFeatures, _allowedFeatures.join(','));
    await sp.setBool(_kCanCreate, _canCreate);
    await sp.setBool(_kCanUpdate, _canUpdate);
    await sp.setBool(_kCanDelete, _canDelete);
  }

  Future<void> _loadPermissionsFromStorage() async {
    final sp = await SharedPreferences.getInstance();
    _allowAllFeatures = sp.getBool(_kAllowAllFeatures) ?? false;
    final csv = sp.getString(_kAllowedFeatures);
    if (csv != null) {
      final list = csv
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      _allowedFeatures = Set<String>.from(list);
    }
    _canCreate = sp.getBool(_kCanCreate) ?? false;
    _canUpdate = sp.getBool(_kCanUpdate) ?? false;
    _canDelete = sp.getBool(_kCanDelete) ?? false;
    _permissionsLoaded = sp.containsKey(_kAllowAllFeatures) ||
        sp.containsKey(_kAllowedFeatures) ||
        sp.containsKey(_kCanCreate) ||
        sp.containsKey(_kCanUpdate) ||
        sp.containsKey(_kCanDelete);
    if (_permissionsLoaded) {
      _permissionsError = null;
    }
  }

  Future<void> _persistUser() async {
    if (currentUser == null) {
      await _clearStorage();
      return;
    }
    final sp = await SharedPreferences.getInstance();
    final oldUid = sp.getString(_kUid);
    final oldAccountId = await ActiveAccountStore.readAccountId(
      allowPendingWipe: true,
    );
    final newUid = (currentUser!['uid'] ?? '').toString();
    final newAccountId = (currentUser!['accountId'] ?? '').toString().trim();
    final uidChanged = oldUid != null && oldUid.isNotEmpty && oldUid != newUid;
    final accountChanged = oldAccountId != null &&
        oldAccountId.isNotEmpty &&
        newAccountId.isNotEmpty &&
        oldAccountId != newAccountId;
    if (uidChanged || accountChanged) {
      await _applyPendingLocalWipeState(
        reason: uidChanged
            ? 'persist_user_uid_change'
            : 'persist_user_account_change',
        accountId: newAccountId.isEmpty ? oldAccountId : newAccountId,
        notify: false,
      );
    }
    await sp.setString(_kUid, currentUser!['uid'] ?? '');
    await sp.setString(_kEmail, currentUser!['email'] ?? '');
    final acc = newAccountId;
    await ActiveAccountStore.writeAccountId(acc.isEmpty ? null : acc);
    await sp.setString(
        _kRole, (currentUser!['role'] ?? '').toString().toLowerCase());
    await sp.setBool(_kDisabled, currentUser!['disabled'] ?? false);
    await sp.setString(_kPlanCode,
        (currentUser!['planCode'] ?? 'free').toString().toLowerCase());
    final chatCode = (currentUser?['chatCode'] ?? '').toString().trim();
    if (chatCode.isNotEmpty) {
      await sp.setString(_kChatCode, chatCode);
    } else {
      await sp.remove(_kChatCode);
    }
    final storedPlanEnd = _readPlanEndAt(currentUser?['planEndAt']);
    if (storedPlanEnd != null) {
      await sp.setString(_kPlanEndAt, storedPlanEnd.toIso8601String());
    } else {
      await sp.remove(_kPlanEndAt);
    }
    if (deviceId != null) {
      await sp.setString(_kDeviceId, deviceId!);
    }
  }

  Future<void> _loadFromStorage() async {
    final sp = await SharedPreferences.getInstance();
    final uid = sp.getString(_kUid);
    final accountId = sp.getString(_kAccountId);
    final role = sp.getString(_kRole);
    final disabled = sp.getBool(_kDisabled);
    final planCode = sp.getString(_kPlanCode);
    final planEndRaw = sp.getString(_kPlanEndAt);
    final chatCode = sp.getString(_kChatCode);
    final planEndAt = _readPlanEndAt(planEndRaw);
    final savedDev = sp.getString(_kDeviceId);

    if (uid != null && uid.isNotEmpty) {
      final isSuper = (role ?? '').toLowerCase() == 'superadmin';
      currentUser = {
        'uid': uid,
        'email': sp.getString(_kEmail),
        'accountId': accountId,
        'role': (role ?? '').toLowerCase(),
        'disabled': disabled ?? false,
        'isSuperAdmin': isSuper,
        'planCode': (planCode ?? 'free').toLowerCase(),
        if (planEndAt != null) 'planEndAt': planEndAt,
        if (chatCode != null && chatCode.isNotEmpty) 'chatCode': chatCode,
      };
      if (savedDev != null && savedDev.isNotEmpty) {
        deviceId = savedDev;
      }

      AuthRoleState.setSuperAdmin(isSuper);

      // حمّل صلاحيات الميزات من التخزين كذلك
      await _loadPermissionsFromStorage();
      _pendingLocalWipe = await ActiveAccountStore.hasPendingWipe();
      _pendingWipeAccountId =
          await ActiveAccountStore.readPendingWipeAccountId();
      if (_pendingLocalWipe) {
        _resetPermissionsInMemory();
      }
    } else {
      currentUser = null;
      _resetPermissionsInMemory();
      _pendingLocalWipe = false;
      _pendingWipeAccountId = null;
    }
  }

  Future<void> _clearStorage() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kUid);
    await sp.remove(_kEmail);
    await ActiveAccountStore.clearAccountId();
    await sp.remove(_kRole);
    await sp.remove(_kDisabled);
    await sp.remove(_kPlanCode);
    await sp.remove(_kPlanEndAt);
    await sp.remove(_kChatCode);
    // لا نحذف _kDeviceId لأنه مُعرّف جهاز ثابت على مستوى الجهاز.

    // نظّف أيضًا الصلاحيات المخزّنة
    await sp.remove(_kAllowedFeatures);
    await sp.remove(_kAllowAllFeatures);
    await sp.remove(_kCanCreate);
    await sp.remove(_kCanUpdate);
    await sp.remove(_kCanDelete);

    AuthRoleState.clear();
    NhostGraphqlService.refreshClient();
  }

  DateTime? _readPlanEndAt(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value.trim());
    }
    return null;
  }

  bool _isPlanExpired() {
    final code = planCode.toLowerCase();
    if (code == 'free') return false;
    final endAt = planEndAt;
    if (endAt == null) return false;
    final endUtc = endAt.isUtc ? endAt : endAt.toUtc();
    final nowUtc = DateTime.now().toUtc();
    return !endUtc.isAfter(nowUtc);
  }

  Future<void> _restartDoctorPatientAlerts() async {
    await _stopDoctorPatientAlerts();
    if (!isLoggedIn) return;
    final userUid = uid;
    if (userUid == null || userUid.isEmpty) return;
    final doctor = await DBService.instance.getDoctorByUserUid(userUid);
    final doctorId = doctor?.id;
    if (doctorId == null) return;
    _patientAlertDoctorId = doctorId;
    _pendingPatientAlerts = <int>{};
    await _scanDoctorPatientAlerts(initial: true);
    _patientAlertSub = DBService.instance.changes.listen((table) {
      if (table == 'patients') {
        _schedulePatientAlertScan();
      }
    });
  }

  void _schedulePatientAlertScan() {
    _patientAlertDebounce?.cancel();
    _patientAlertDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_scanDoctorPatientAlerts(initial: false));
    });
  }

  Future<void> _scanDoctorPatientAlerts({required bool initial}) async {
    final doctorId = _patientAlertDoctorId;
    if (doctorId == null) return;
    final db = await DBService.instance.database;
    final rows = await db.query(
      'patients',
      columns: const ['id', 'name'],
      where:
          'ifnull(isDeleted,0)=0 AND ifnull(doctorReviewPending,0)=1 AND doctorId = ?',
      whereArgs: [doctorId],
    );
    final current = <int, String>{};
    for (final row in rows) {
      final rawId = row['id'];
      final id = rawId is num ? rawId.toInt() : int.tryParse('${rawId ?? ''}');
      if (id == null) continue;
      final name = (row['name'] as String?) ?? '';
      current[id] = name;
    }

    final currentIds = current.keys.toSet();
    if (!initial) {
      final newIds = currentIds.difference(_pendingPatientAlerts);
      for (final id in newIds) {
        final label = current[id]?.trim();
        final patientName =
            (label == null || label.isEmpty) ? 'مريض جديد' : label;
        try {
          await NotificationService().showPatientAssignmentNotification(
            patientId: id,
            patientName: patientName,
          );
        } catch (e) {
          dev.log('showPatientAssignmentNotification failed', error: e);
        }
      }
    }
    _pendingPatientAlerts = currentIds;
  }

  Future<void> _stopDoctorPatientAlerts() async {
    await _patientAlertSub?.cancel();
    _patientAlertSub = null;
    _patientAlertDebounce?.cancel();
    _patientAlertDebounce = null;
    _pendingPatientAlerts = <int>{};
    _patientAlertDoctorId = null;
  }

  bool _bootstrapBusy = false;
  Future<void> bootstrapSync({
    bool pull = true,
    bool realtime = true,
    bool enableLogs = true,
    Duration debounce = const Duration(seconds: 1),
    bool wipeLocalFirst = false,
  }) async {
    if (_bootstrapBusy) return;
    if (!isLoggedIn || isSuperAdmin || requiresLocalIsolationWipe) {
      await _stopDoctorPatientAlerts();
      return;
    }
    _bootstrapBusy = true;
    try {
      await _auth.bootstrapSyncForCurrentUser(
        pull: pull,
        realtime: realtime,
        enableLogs: enableLogs,
        debounce: debounce,
        wipeLocalFirst: wipeLocalFirst,
      );
      final accId = accountId;
      if (accId != null &&
          accId.trim().isNotEmpty &&
          _lastBackfilledSyncAccountId != accId.trim()) {
        await DBService.instance.backfillAccountForTables(const [
          'patients',
          'returns',
          'consumptions',
          'drugs',
          'prescriptions',
          'prescription_items',
          'complaints',
          'appointments',
          'doctors',
          'consumption_types',
          'medical_services',
          'service_doctor_share',
          'employees',
          'employees_loans',
          'employees_salaries',
          'employees_discounts',
          'items',
          'item_types',
          'purchases',
          'alert_settings',
          'financial_logs',
          'patient_services',
        ], accId);
        _lastBackfilledSyncAccountId = accId.trim();
      }
      await refreshPendingLocalWipeState();
      if (requiresLocalIsolationWipe) {
        await _stopDoctorPatientAlerts();
        return;
      }
      await _restartDoctorPatientAlerts();
    } catch (e, st) {
      await _stopDoctorPatientAlerts();
      dev.log('AuthProvider.bootstrapSync failed', error: e, stackTrace: st);
      _authObsError(
        ObsCode.authBootstrapSyncFailed,
        'bootstrapSync failed',
        flowId: _newAuthFlow('bootstrap_sync'),
        context: {
          'pull': pull,
          'realtime': realtime,
          'wipeLocalFirst': wipeLocalFirst,
        },
        error: e,
        stackTrace: st,
      );
    } finally {
      _bootstrapBusy = false;
    }
  }

  /// مزامنة فورية بسيطة (تعيد bootstrap لضمان pull حديث).
  Future<void> syncNow() async {
    await bootstrapSync(
      pull: true,
      realtime: true,
      enableLogs: true,
    );
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _patientAlertSub?.cancel();
    _patientAlertDebounce?.cancel();
    _netSub?.cancel();
    super.dispose();
  }
}
