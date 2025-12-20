// lib/providers/auth_provider.dart
//
// مزوّد حالة المصادقة + صلاحيات الميزات + Bootstrap للمزامنة.
// النقاط الأساسية:
// - توحيد مصدر الحقيقة مع NhostAuthService (تفويض bootstrap/guards للمزامنة).
// - تخزين محلي خفيف (SharedPreferences) لآخر هوية + صلاحيات الميزات.
// - تحديث role/isSuperAdmin بصيغة موحّدة (superadmin بحروف صغيرة).
// - إزالة إدارة SyncService المباشرة من المزوّد (لا مؤقّت 60 ثانية)،
//   والاعتماد على bootstrapSyncForCurrentUser من NhostAuthService الذي يشمل:
//   parity v3 + ربط push debounced + Realtime + حراسة الحساب/الموظف.

import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:meta/meta.dart';
import 'package:flutter/widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:nhost_dart/nhost_dart.dart';

import 'package:aelmamclinic/core/features.dart'; // FeatureKeys.chat
import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/models/account_policy.dart';
import 'package:aelmamclinic/models/backend_errors.dart';
import 'package:aelmamclinic/models/feature_permissions.dart';
import 'package:aelmamclinic/services/nhost_auth_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/device_id_service.dart';
import 'package:aelmamclinic/services/notification_service.dart';
import 'package:aelmamclinic/utils/logger.dart';

/// مفاتيح التخزين المحلي
const _kUid = 'auth.uid';
const _kEmail = 'auth.email';
const _kRole = 'auth.role';
const _kDisabled = 'auth.disabled';
const _kDeviceId = 'auth.deviceId';
const _kLastNetCheckAt = 'auth.lastNetCheckAt';
const int _kNetCheckIntervalDays = 30; // فحص شبكة كل 30 يوم

// مفاتيح صلاحيات الميزات + CRUD
const _kAllowedFeatures = 'auth.allowedFeatures'; // CSV
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
  backendMisconfigured,
  signedOut,
  transientFailure,
  unknown,
}

/// حالة التحقق بعد تحديث بيانات المستخدم من الشبكة وحراسة الحساب.
enum AuthSessionStatus {
  success,
  disabled,
  accountFrozen,
  noAccount,
  backendMisconfigured,
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
  const AuthSessionResult.disabled() : this._(AuthSessionStatus.disabled);
  const AuthSessionResult.accountFrozen()
      : this._(AuthSessionStatus.accountFrozen);
  const AuthSessionResult.noAccount() : this._(AuthSessionStatus.noAccount);
  const AuthSessionResult.backendMisconfigured()
      : this._(AuthSessionStatus.backendMisconfigured);
  const AuthSessionResult.signedOut() : this._(AuthSessionStatus.signedOut);
  const AuthSessionResult.networkError({Object? error, StackTrace? stackTrace})
      : this._(
          AuthSessionStatus.networkError,
          error: error,
          stackTrace: stackTrace,
        );
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
  Set<String> _allowedFeatures = <String>{};
  bool _canCreate = true;
  bool _canUpdate = true;
  bool _canDelete = true;
  bool _permissionsLoaded = false;
  String? _permissionsError;
  bool _permissionsWarningShown = false;
  bool _superAdminSyncWarningShown = false;

  Set<String> get allowedFeatures => _allowedFeatures;
  bool get canCreate => isSuperAdmin || (_permissionsLoaded && _canCreate);
  bool get canUpdate => isSuperAdmin || (_permissionsLoaded && _canUpdate);
  bool get canDelete => isSuperAdmin || (_permissionsLoaded && _canDelete);
  bool get permissionsLoaded => _permissionsLoaded;
  String? get permissionsError => _permissionsError;

  FeaturePermissions _snapshotPermissions() => FeaturePermissions(
        allowedFeatures: Set<String>.from(_allowedFeatures),
        canCreate: _canCreate,
        canUpdate: _canUpdate,
        canDelete: _canDelete,
      );

  /// اعتبارًا لمخطط الـ SQL: إذا كانت القائمة فارغة فهذا يعني "لا قيود" (الكل مسموح).
  bool featureAllowed(String featureKey) {
    if (isSuperAdmin) return true;
    if (!_permissionsLoaded) return false;
    if (_allowedFeatures.isEmpty) return true;
    return _allowedFeatures.contains(featureKey);
  }

  /// اختصار مفيد لميزة الدردشة
  bool get chatEnabled => isSuperAdmin || featureAllowed(FeatureKeys.chat);

  // === إدارة تدفّق المصادقة ===
  StreamSubscription<AuthenticationState>? _authSub;
  Timer? _authStateDebounce;
  AuthenticationState? _pendingAuthState;
  bool _authStateInFlight = false;
  AuthenticationState? _lastHandledAuthState;
  StreamSubscription<String>? _patientAlertSub;
  Timer? _patientAlertDebounce;
  Set<int> _pendingPatientAlerts = <int>{};
  int? _patientAlertDoctorId;

  /*──────── Getters ────────*/
  bool get isLoggedIn => currentUser != null;
  String? get uid => currentUser?['uid'] as String?;
  String? get email => currentUser?['email'] as String?;
  String? get role => currentUser?['role'] as String?;
  String? get accountId => currentUser?['accountId'] as String?;
  bool get isDisabled => (currentUser?['disabled'] as bool?) ?? false;
  bool get isSuperAdmin => currentUser?['isSuperAdmin'] == true;

  AuthProvider({
    NhostAuthService? authService,
    bool listenAuthChanges = true,
  }) : _auth = authService ?? NhostAuthService() {
    if (listenAuthChanges) {
      // الاستماع لتغيّرات المصادقة مع دمج سريع لتقليل التكرار.
      _authSub = _auth.authStateChanges.listen((state) {
        _pendingAuthState = state;
        _authStateDebounce?.cancel();
        _authStateDebounce = Timer(const Duration(milliseconds: 250), () {
          final effective = _pendingAuthState;
          if (effective == null) return;
          unawaited(_handleAuthStateChange(effective));
        });
      });
    }
  }

  Future<void> _handleAuthStateChange(AuthenticationState state) async {
    if (_authStateInFlight) {
      _pendingAuthState = state;
      return;
    }
    if (state == _lastHandledAuthState &&
        state != AuthenticationState.signedIn) {
      return;
    }
    _authStateInFlight = true;
    _lastHandledAuthState = state;
    if (state == AuthenticationState.signedOut) {
      // هذه الإشارة تأتي بعد signOut — نظّف الحالة المحلية فقط.
      currentUser = null;
      _resetPermissionsInMemory();
      await _stopDoctorPatientAlerts();
      await _clearStorage();
      notifyListeners();
      _authStateInFlight = false;
      return;
    }

    // لأي حدث آخر: نحدّث من الشبكة عند الدخول أو عند حلول موعد الفحص
    final due = await _isNetCheckDue();
    if (state == AuthenticationState.signedIn || due) {
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
        } catch (_) {}
      }
    }

    // تحقّق من الحساب الفعّال (غير مجمّد/غير معطّل)
    await _ensureActiveAccountOrSignOut();
    if (isDisabled) {
      await _auth.signOut();
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
    _authStateInFlight = false;
    final pending = _pendingAuthState;
    if (pending != null && pending != state) {
      _pendingAuthState = null;
      await _handleAuthStateChange(pending);
    }
  }

  /// نادِها في main() بعد تهيئة Nhost
  Future<void> init() async {
    final signedIn = _auth.client.auth.currentUser != null;
    if (signedIn) {
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
          } catch (_) {}
        }
      }
    } else {
      await _loadFromStorage();
      await _ensureDeviceId();
      await _loadPermissionsFromStorage();
      notifyListeners();
      return;
    }

    // تأكيد الحساب الفعّال
    await _ensureActiveAccountOrSignOut();

    await _ensureDeviceId();

    // تحميل الصلاحيات من التخزين (إن وُجدت) ثم محاولة تحديثها من الشبكة
    await _loadPermissionsFromStorage();
    if (accountId != null && accountId!.isNotEmpty && !isSuperAdmin) {
      unawaited(_refreshFeaturePermissions());
    }

    if (isLoggedIn) {
      unawaited(bootstrapSync());
    }

    notifyListeners();
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

  Future<void> signIn(String email, String password) async {
    await _auth.signInWithEmailPassword(email: email, password: password);
    // سيستكمل الـ listener ما يلزم (refresh/permissions/bootstrap).
  }

  Future<void> signOut() async {
    await _auth.signOut(); // يوقف المزامنة/الحراسة داخليًا

    currentUser = null;
    _resetPermissionsInMemory();

    final sp = await SharedPreferences.getInstance();
    await _clearStorage();
    await sp.remove(_kLastNetCheckAt);

    notifyListeners();
  }

  /// يجري تحديثًا كاملاً من الشبكة ثم يتحقق من صلاحية الحساب الحالي.
  Future<AuthSessionResult> refreshAndValidateCurrentUser() async {
    try {
      final refreshed = await _networkRefreshAndMark();
      final guard = await _ensureActiveAccountOrSignOut();

      switch (guard) {
        case AuthAccountGuardResult.ok:
          if (!isSuperAdmin) {
            final accId = accountId;
            if (accId == null || accId.isEmpty) {
              return refreshed
                  ? const AuthSessionResult.noAccount()
                  : const AuthSessionResult.networkError();
            }
          }
          notifyListeners();
          return const AuthSessionResult.success();
        case AuthAccountGuardResult.accountFrozen:
          return const AuthSessionResult.accountFrozen();
        case AuthAccountGuardResult.disabled:
          return const AuthSessionResult.disabled();
        case AuthAccountGuardResult.noAccount:
          return const AuthSessionResult.noAccount();
        case AuthAccountGuardResult.backendMisconfigured:
          return const AuthSessionResult.backendMisconfigured();
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

  /// تغيير سياق الحساب (مثلاً المالك يبدّل بين عيادات)
  Future<void> setAccountContext(String newAccountId) async {
    if (currentUser == null) return;
    currentUser!['accountId'] = newAccountId;
    await _persistUser();

    // مسح البيانات المحلية كي لا تختلط بين الحسابات المختلفة
    try {
      await DBService.instance.clearAllLocalTables();
    } catch (_) {}

    // تحديث الصلاحيات للحساب الجديد
    await _refreshFeaturePermissions();

    // إعادة Bootstrap للمزامنة على الحساب الجديد
    unawaited(
      _auth.bootstrapSyncForCurrentUser(
        pull: true,
        realtime: true,
        enableLogs: true,
        wipeLocalFirst: false, // قمنا بالتصفير مسبقًا
      ),
    );

    notifyListeners();
  }

  /// تحديث يدوي للصلاحيات (مفيد بعد تغيير إعدادات المالك)
  Future<void> refreshPermissions() => _refreshFeaturePermissions();

  /// أدوات مساعدة اختيارية: تغيير كلمة مرور/إعادة تعيين/تحديث جلسة
  Future<void> changePassword(String newPassword) =>
      _auth.changePassword(newPassword);
  Future<void> requestPasswordReset(String email, {String? redirectTo}) =>
      _auth.requestPasswordReset(email, redirectTo: redirectTo);
  Future<void> refreshSession() => _auth.refreshSession();

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

  Future<bool> _networkRefreshAndMark() async {
    if (_refreshInFlight) {
      return false;
    }
    final now = DateTime.now();
    if (_lastRefreshAt != null &&
        now.difference(_lastRefreshAt!) < const Duration(seconds: 1)) {
      return false;
    }
    _refreshInFlight = true;
    _lastRefreshAt = now;
    try {
      final startCtx = <String, Object?>{
        'uid': currentUser?['uid'],
        'hasAccount': ((currentUser?['accountId'] ?? '').toString().isNotEmpty),
      };
      _authDiag('_networkRefreshAndMark:start', context: startCtx);
      bool success = false;
      try {
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
          } catch (_) {}
        }

        final roleValue =
            (currentUser?['role'] ?? '').toString().toLowerCase().trim();
        final isSuper =
            roleValue == 'superadmin' || currentUser?['isSuperAdmin'] == true;

        if (!isSuper &&
            (((currentUser?['accountId'] ?? '').toString().isEmpty) ||
                ((currentUser?['role'] ?? '').toString().isEmpty))) {
          try {
            final aa = await _auth.resolveActiveAccountOrThrow();
            currentUser ??= {};
            currentUser!['accountId'] = aa.id;
            currentUser!['role'] = aa.role.toLowerCase();
            currentUser!['disabled'] = false;
            _authDiag(
              '_networkRefreshAndMark:resolvedViaActiveAccount',
              context: {'accountId': aa.id, 'role': aa.role},
            );
          } catch (e, st) {
            if (e is AccountPolicyException || e is ApiException) {
              rethrow;
            }
            _authDiagWarn(
              '_networkRefreshAndMark:activeAccountFallbackFailed',
              context: {
                'uid': currentUser?['uid'],
                'error': e.runtimeType.toString(),
              },
              stackTrace: st,
            );
          }
        }

        final hasAccount =
            ((currentUser?['accountId'] ?? '').toString().isNotEmpty);
        success = hasAccount || isSuper;
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
      }

      await _persistUser();
      _authDiag(
        '_networkRefreshAndMark:persisted',
        context: {
          'uid': currentUser?['uid'],
          'accountId': currentUser?['accountId'],
          'success': success,
        },
      );

      if (success) {
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_kLastNetCheckAt, DateTime.now().toIso8601String());
        _authDiag(
          '_networkRefreshAndMark:success',
          context: {
            'accountId': currentUser?['accountId'],
            'role': currentUser?['role'],
          },
        );
      } else {
        final roleValue =
            (currentUser?['role'] ?? '').toString().toLowerCase().trim();
        if (roleValue == 'superadmin' || currentUser?['isSuperAdmin'] == true) {
          _authDiag(
            '_networkRefreshAndMark:superAdminNoAccountBypass',
            context: {'uid': currentUser?['uid']},
          );
          return true;
        }
        _authDiagWarn(
          '_networkRefreshAndMark:missingAccountId',
          context: {'uid': currentUser?['uid']},
        );
      }
      return success;
    } finally {
      _refreshInFlight = false;
    }
  }

  bool _isTransientNetworkError(Object error) {
    return error is SocketException ||
        error is TimeoutException ||
        error is OperationException ||
        error is ApiException;
  }

  bool _isBackendConfigError(Object error) {
    if (error is BackendSchemaException) {
      return true;
    }
    if (error is StateError) {
      final msg = error.message.toLowerCase();
      return msg.contains('backend schema') ||
          msg.contains('metadata') ||
          msg.contains('schema');
    }
    return false;
  }

  Future<bool> _isNetCheckDue() async {
    final sp = await SharedPreferences.getInstance();
    final iso = sp.getString(_kLastNetCheckAt);
    if (iso == null) return true;
    final last = DateTime.tryParse(iso);
    if (last == null) return true;
    return DateTime.now().difference(last).inDays >= _kNetCheckIntervalDays;
  }

  /// يجلب بيانات المستخدم من السيرفر مع حسم accountId مؤكد عبر عدة fallbacks
  Future<void> _refreshUser() async {
    final u = _auth.client.auth.currentUser;
    if (u == null) {
      currentUser = null;
      _resetPermissionsInMemory();
      return;
    }

    Map<String, dynamic>? info;
    try {
      info = await _auth
          .fetchCurrentUser(); // { uid,email,accountId,role,isSuperAdmin }
    } catch (e, st) {
      info = null;
      _authDiagWarn(
        '_refreshUser:fetchCurrentUser_failed',
        context: {'error': e.toString()},
        stackTrace: st,
      );
    }

    // accountId مبدئيًا من info
    String? accId = info?['accountId'] as String?;

    // Fallback لحسم accountId
    if (accId == null || accId.isEmpty) {
      try {
        accId = await _auth.resolveAccountId();
      } catch (e, st) {
        _authDiagWarn(
          '_refreshUser:resolveAccountId_failed',
          context: {'error': e.toString()},
          stackTrace: st,
        );
      }
    }

    // الدور والبريد — توحيد role = 'superadmin' إن كان سوبر
    final emailLower = (u.email ?? info?['email'] ?? '').toLowerCase();
    final infoRole = (info?['role'] as String?)?.toLowerCase();
    final bool infoIsSuper = info?['isSuperAdmin'] == true;
    final role = infoIsSuper ? 'superadmin' : (infoRole ?? 'employee');
    final isSuper = infoIsSuper || role == 'superadmin';

    if (!infoIsSuper && _isSuperAdminEmail(emailLower)) {
      if (!_superAdminSyncWarningShown) {
        _superAdminSyncWarningShown = true;
        final message =
            'تنبيه: هذا البريد مُعرّف كسوبر أدمن محليًا لكن لم تتم مزامنته على الخادم بعد. الرجاء تشغيل مزامنة super_admins.';
        if (Platform.isAndroid || Platform.isIOS) {
          Fluttertoast.showToast(
            msg: message,
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.BOTTOM,
          );
        } else {
          dev.log(message, name: 'AUTH');
        }
      }
    }

    currentUser = {
      'uid': u.id,
      'email': u.email ?? info?['email'],
      'accountId': accId, // ← المهم
      'role': role,
      'disabled': info?['disabled'] == true,
      'isSuperAdmin': isSuper,
      if (deviceId != null) _kDeviceId: deviceId,
    };
  }

  bool _isSuperAdminEmail(String? email) {
    final normalized = (email ?? '').trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return AppConstants.superAdminEmails.contains(normalized);
  }

  /// يتأكد أن الحساب الفعّال قابل للكتابة (غير مجمّد/غير معطّل) وإلا يخرج.
  Future<AuthAccountGuardResult> _ensureActiveAccountOrSignOut() async {
    if (!isLoggedIn) {
      _authDiag('_ensureActiveAccountOrSignOut:signedOutEarly');
      return AuthAccountGuardResult.signedOut;
    }
    if (isSuperAdmin) {
      _authDiag(
        '_ensureActiveAccountOrSignOut:superAdminBypass',
        context: {'uid': uid},
      );
      return AuthAccountGuardResult.ok; // السوبر أدمن خارج نطاق الحسابات
    }
    _authDiag(
      '_ensureActiveAccountOrSignOut:start',
      context: {'uid': uid, 'accountId': accountId},
    );
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        _authDiag(
          '_ensureActiveAccountOrSignOut:attempt',
          context: {'attempt': attempt, 'max': maxAttempts},
        );
        final aa = await _auth.resolveActiveAccountOrThrow();
        currentUser ??= {};
        currentUser!['accountId'] = aa.id;
        currentUser!['role'] = aa.role.toLowerCase();
        currentUser!['disabled'] = false;
        await _persistUser();
        _authDiag(
          '_ensureActiveAccountOrSignOut:ok',
          context: {'accountId': aa.id, 'role': aa.role},
        );
        return AuthAccountGuardResult.ok;
      } catch (e, st) {
        if (_isBackendConfigError(e)) {
          _authDiagWarn(
            '_ensureActiveAccountOrSignOut:backendMisconfigured',
            context: {'error': e.toString()},
            stackTrace: st,
          );
          return AuthAccountGuardResult.backendMisconfigured;
        }
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
              'Keeping session after transient failure to validate account.',
            );
            _authDiagWarn(
              '_ensureActiveAccountOrSignOut:transientGivingUp',
              context: {'attempt': attempt, 'error': e.runtimeType.toString()},
            );
            return AuthAccountGuardResult.transientFailure;
          }
          await Future.delayed(delay);
          continue;
        }

        AuthAccountGuardResult result = AuthAccountGuardResult.disabled;
        if (e is AccountFrozenException) {
          result = AuthAccountGuardResult.accountFrozen;
        } else if (e is AccountUserDisabledException) {
          result = AuthAccountGuardResult.disabled;
        } else if (e is StateError) {
          final lower = e.message.toLowerCase();
          if (lower.contains('no active clinic') ||
              lower.contains('unable to resolve account')) {
            result = AuthAccountGuardResult.noAccount;
          }
        }

        dev.log('Active account invalid: $e', stackTrace: st);
        currentUser ??= {};
        currentUser!['disabled'] = true;
        await _persistUser();
        _authDiagError(
          '_ensureActiveAccountOrSignOut:failure',
          context: {'result': result.name, 'attempt': attempt},
          error: e,
          stackTrace: st,
        );
        await signOut();
        return result;
      }
    }
    _authDiagWarn(
      '_ensureActiveAccountOrSignOut:unknownOutcome',
      context: {'uid': uid},
    );
    return AuthAccountGuardResult.unknown;
  }

  /// يجلب صلاحيات الميزات + CRUD للحساب الحالي ويخزّنها محليًا
  Future<void> _refreshFeaturePermissions() async {
    final accId = accountId;
    if (accId == null || accId.isEmpty) return;
    try {
      final perms = await _auth.fetchMyFeaturePermissions(
        accountId: accId,
        fallback: _snapshotPermissions(),
      );
      _allowedFeatures = perms.allowedFeatures;
      _canCreate = perms.canCreate;
      _canUpdate = perms.canUpdate;
      _canDelete = perms.canDelete;
      _permissionsLoaded = true;
      _permissionsError = null;
      _permissionsWarningShown = false;
      await _persistPermissions();
    } catch (e, st) {
      dev.log('refreshFeaturePermissions failed', error: e, stackTrace: st);
      _authDiagWarn(
        '_refreshFeaturePermissions:error',
        context: {'error': e.toString()},
        stackTrace: st,
      );
      if (e is FeaturePermissionsFetchException && e.fallback != null) {
        _allowedFeatures = e.fallback!.allowedFeatures;
        _canCreate = e.fallback!.canCreate;
        _canUpdate = e.fallback!.canUpdate;
        _canDelete = e.fallback!.canDelete;
      } else {
        _allowedFeatures = <String>{};
        _canCreate = false;
        _canUpdate = false;
        _canDelete = false;
      }
      _permissionsLoaded = false;
      _permissionsError = '${e}';
      _showPermissionsFallbackWarning();
    }
    notifyListeners();
  }

  void _resetPermissionsInMemory() {
    _allowedFeatures = <String>{};
    _canCreate = true;
    _canUpdate = true;
    _canDelete = true;
    _permissionsLoaded = false;
    _permissionsError = null;
    _permissionsWarningShown = false;
  }

  void _showPermissionsFallbackWarning() {
    if (_permissionsWarningShown) return;
    _permissionsWarningShown = true;
    Fluttertoast.showToast(
      msg:
          'تعذّر تحديث صلاحيات الميزات، سيتم استخدام آخر إعدادات محفوظة إلى حين عودة الاتصال.',
      toastLength: Toast.LENGTH_LONG,
    );
  }

  Future<void> _persistPermissions() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kAllowedFeatures, _allowedFeatures.join(','));
    await sp.setBool(_kCanCreate, _canCreate);
    await sp.setBool(_kCanUpdate, _canUpdate);
    await sp.setBool(_kCanDelete, _canDelete);
  }

  Future<void> _loadPermissionsFromStorage() async {
    final sp = await SharedPreferences.getInstance();
    final csv = sp.getString(_kAllowedFeatures);
    if (csv != null) {
      final list = csv
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      _allowedFeatures = Set<String>.from(list);
    }
    _canCreate = sp.getBool(_kCanCreate) ?? true;
    _canUpdate = sp.getBool(_kCanUpdate) ?? true;
    _canDelete = sp.getBool(_kCanDelete) ?? true;
    _permissionsLoaded = sp.containsKey(_kAllowedFeatures) ||
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
    await sp.setString(_kUid, currentUser!['uid'] ?? '');
    await sp.setString(_kEmail, currentUser!['email'] ?? '');
    await ActiveAccountStore.writeAccountId(currentUser!['accountId'] ?? '');
    await sp.setString(
      _kRole,
      (currentUser!['role'] ?? '').toString().toLowerCase(),
    );
    await sp.setBool(_kDisabled, currentUser!['disabled'] ?? false);
    if (deviceId != null) {
      await sp.setString(_kDeviceId, deviceId!);
    }
  }

  Future<void> _loadFromStorage() async {
    final sp = await SharedPreferences.getInstance();
    final uid = sp.getString(_kUid);
    final email = sp.getString(_kEmail);
    final accountId = await ActiveAccountStore.readAccountId();
    final role = sp.getString(_kRole);
    final disabled = sp.getBool(_kDisabled);
    final savedDev = sp.getString(_kDeviceId);

    if (uid != null && uid.isNotEmpty) {
      currentUser = {
        'uid': uid,
        'email': email,
        'accountId': accountId,
        'role': (role ?? '').toLowerCase(),
        'disabled': disabled ?? false,
        'isSuperAdmin': (role ?? '').toLowerCase() == 'superadmin',
      };
      if (savedDev != null && savedDev.isNotEmpty) {
        deviceId = savedDev;
      }

      // حمّل صلاحيات الميزات من التخزين كذلك
      await _loadPermissionsFromStorage();
    } else {
      currentUser = null;
      _resetPermissionsInMemory();
    }
  }

  Future<void> _clearStorage() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kUid);
    await sp.remove(_kEmail);
    await ActiveAccountStore.clearAccountId();
    await sp.remove(_kRole);
    await sp.remove(_kDisabled);
    // لا نحذف _kDeviceId لأنه مُعرّف جهاز ثابت على مستوى الجهاز.

    // نظّف أيضًا الصلاحيات المخزّنة
    await sp.remove(_kAllowedFeatures);
    await sp.remove(_kCanCreate);
    await sp.remove(_kCanUpdate);
    await sp.remove(_kCanDelete);
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
  bool _refreshInFlight = false;
  DateTime? _lastRefreshAt;
  Future<void> bootstrapSync({
    bool pull = true,
    bool realtime = true,
    bool enableLogs = true,
    Duration debounce = const Duration(seconds: 1),
    bool wipeLocalFirst = false,
  }) async {
    if (_bootstrapBusy) return;
    if (!isLoggedIn || isSuperAdmin) {
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
      await _restartDoctorPatientAlerts();
    } catch (e, st) {
      await _stopDoctorPatientAlerts();
      dev.log('AuthProvider.bootstrapSync failed', error: e, stackTrace: st);
    } finally {
      _bootstrapBusy = false;
    }
  }

  /// مزامنة فورية بسيطة (تعيد bootstrap لضمان pull حديث).
  Future<void> syncNow() async {
    await bootstrapSync(pull: true, realtime: true, enableLogs: true);
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _authStateDebounce?.cancel();
    _patientAlertSub?.cancel();
    _patientAlertDebounce?.cancel();
    unawaited(_auth.dispose());
    super.dispose();
  }
}
