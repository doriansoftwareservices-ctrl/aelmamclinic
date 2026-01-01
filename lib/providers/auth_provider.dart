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
import 'package:meta/meta.dart';
import 'package:flutter/widgets.dart';
import 'package:nhost_dart/nhost_dart.dart';
import 'package:nhost_sdk/nhost_sdk.dart' show AuthResponse;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aelmamclinic/core/features.dart'; // FeatureKeys.chat
import 'package:aelmamclinic/models/account_policy.dart';
import 'package:aelmamclinic/services/nhost_auth_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/device_id_service.dart';
import 'package:aelmamclinic/services/notification_service.dart';
import 'package:aelmamclinic/utils/logger.dart';

/// مفاتيح التخزين المحلي
const _kUid = 'auth.uid';
const _kEmail = 'auth.email';
const _kAccountId = 'auth.accountId';
const _kRole = 'auth.role';
const _kDisabled = 'auth.disabled';
const _kPlanCode = 'auth.planCode';
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
      : this._(AuthSessionStatus.unknown,
            error: error, stackTrace: stackTrace);

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
  bool _allowAutoCreateAccount = false;

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

  /*──────── Getters ────────*/
  bool get isLoggedIn => currentUser != null;
  String? get accessToken => _auth.accessToken;
  String? get uid => currentUser?['uid'] as String?;
  String? get email => currentUser?['email'] as String?;
  String? get role => currentUser?['role'] as String?;
  String? get accountId => currentUser?['accountId'] as String?;
  String get planCode =>
      (currentUser?['planCode'] as String?)?.toLowerCase() ?? 'free';
  bool get isPro => isSuperAdmin || planCode != 'free';
  bool get isDisabled => (currentUser?['disabled'] as bool?) ?? false;
  bool get isSuperAdmin => currentUser?['isSuperAdmin'] == true;
  bool get isOwnerOrAdmin {
    if (isSuperAdmin) return true;
    final r = role?.toLowerCase();
    return r == 'owner' || r == 'admin';
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
        _allowAutoCreateAccount = false;
        await _stopDoctorPatientAlerts();
        await _clearStorage();
        notifyListeners();
        return;
      }

        // لأي حدث آخر: نحدّث من الشبكة عند الدخول أو عند حلول موعد الفحص
        final due = await _isNetCheckDue();
        if (event == AuthenticationState.signedIn || due) {
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
      });
    }
  }

  /// نادِها في main() بعد تهيئة Nhost.
  Future<void> init() async {
    final user = _auth.currentUser;
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
          } catch (_) {}
        }
      }
    } else {
      await _loadFromStorage();
      // لا يوجد مستخدم على Nhost، امسح أي حالة محلية قديمة.
      currentUser = null;
      _resetPermissionsInMemory();
      await _clearStorage();
    }

    if (isLoggedIn) {
      // تأكيد الحساب الفعّال
      await _ensureActiveAccountOrSignOut();

      await _ensureDeviceId();

      // تحميل الصلاحيات من التخزين (إن وُجدت) ثم محاولة تحديثها من الشبكة
      await _loadPermissionsFromStorage();
      if (accountId != null && accountId!.isNotEmpty && !isSuperAdmin) {
        unawaited(_refreshFeaturePermissions());
      }

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

  Future<AuthResponse> signIn(String email, String password) {
    return _auth.signInWithEmailPassword(
      email: email,
      password: password,
    );
  }

  Future<AuthResponse> signUp(String email, String password) {
    return _auth.signUpWithEmailPassword(
      email: email,
      password: password,
    );
  }

  Future<String> selfCreateAccount(String clinicName) {
    return _auth.selfCreateAccount(clinicName: clinicName);
  }

  Future<void> signOut() async {
    await _auth.signOut(); // يوقف المزامنة/الحراسة داخليًا

    currentUser = null;
    _resetPermissionsInMemory();
    _autoCreateAttempted = false;

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
    unawaited(_auth.bootstrapSyncForCurrentUser(
      pull: true,
      realtime: true,
      enableLogs: true,
      wipeLocalFirst: false, // قمنا بالتصفير مسبقًا
    ));

    notifyListeners();
  }

  /// تحديث يدوي للصلاحيات (مفيد بعد تغيير إعدادات المالك)
  Future<void> refreshPermissions() => _refreshFeaturePermissions();

  /// أدوات مساعدة اختيارية: تغيير كلمة مرور/إعادة تعيين/تحديث جلسة
  Future<void> changePassword(String newPassword) => _auth.changePassword(newPassword);
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

      if (((currentUser?['accountId'] ?? '').toString().isEmpty) ||
          ((currentUser?['role'] ?? '').toString().isEmpty)) {
        try {
          final aa = await _auth.resolveActiveAccountOrThrow();
          currentUser ??= {};
          currentUser!['accountId'] = aa.id;
          currentUser!['role'] = aa.role.toLowerCase();
          currentUser!['disabled'] = false;
          _authDiag(
            '_networkRefreshAndMark:resolvedViaActiveAccount',
            context: {
              'accountId': aa.id,
              'role': aa.role,
            },
          );
        } catch (e, st) {
          if (e is AccountPolicyException) {
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
    }

    await _persistUser();
    _authDiag('_networkRefreshAndMark:persisted', context: {
      'uid': currentUser?['uid'],
      'accountId': currentUser?['accountId'],
      'success': success,
    });

    if (success) {
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

  bool _isTransientNetworkError(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    final msg = error.toString().toLowerCase();
    return msg.contains('timeout') ||
        msg.contains('timed out') ||
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

    Map<String, dynamic>? info;
    try {
      info = await _auth.fetchCurrentUser(); // { uid,email,accountId,role,isSuperAdmin }
    } catch (_) {
      info = null;
    }

    // accountId مبدئيًا من info
    String? accId = info?['accountId'] as String?;

    // Fallbacks لحسم accountId
    if (accId == null || accId.isEmpty) {
      try {
        accId = await _auth.resolveAccountId();
      } catch (_) {}
    }
    if (accId == null || accId.isEmpty) {
      try {
        final aa = await _auth.resolveActiveAccountOrThrow();
        accId = aa.id;
      } catch (_) {}
    }

    // الدور والبريد — توحيد role = 'superadmin' إن كان سوبر
    final infoRole = (info?['role'] as String?)?.toLowerCase();
    final infoIsSuper = info?['isSuperAdmin'] == true;
    final infoPlan = (info?['planCode'] as String?)?.toLowerCase();
    final role = infoIsSuper ? 'superadmin' : (infoRole ?? 'employee');
    final isSuper = infoIsSuper;

    currentUser = {
      'uid': u.id,
      'email': u.email ?? info?['email'],
      'accountId': accId, // ← المهم
      'role': role,
      'disabled': false, // إن وُجد لديك إشارة تعطيل؛ حدّثها هنا.
      'isSuperAdmin': isSuper,
      'planCode': infoPlan ?? 'free',
      if (deviceId != null) _kDeviceId: deviceId,
    };
  }

  /// يتأكد أن الحساب الفعّال قابل للكتابة (غير مجمّد/غير معطّل) وإلا يخرج.
  Future<AuthAccountGuardResult> _ensureActiveAccountOrSignOut() async {
    if (!isLoggedIn) {
      _authDiag('_ensureActiveAccountOrSignOut:signedOutEarly');
      return AuthAccountGuardResult.signedOut;
    }
    if (isSuperAdmin) {
      _authDiag('_ensureActiveAccountOrSignOut:superAdminBypass', context: {
        'uid': uid,
      });
      return AuthAccountGuardResult.ok; // السوبر أدمن خارج نطاق الحسابات
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
        final aa = await _auth.resolveActiveAccountOrThrow();
        currentUser ??= {};
        currentUser!['accountId'] = aa.id;
        currentUser!['role'] = aa.role.toLowerCase();
        currentUser!['disabled'] = false;
        await _persistUser();
        _authDiag('_ensureActiveAccountOrSignOut:ok', context: {
          'accountId': aa.id,
          'role': aa.role,
        });
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
            dev.log('Keeping session after transient failure to validate account.');
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
            final seed = _seedClinicName();
            _authDiagWarn(
              '_ensureActiveAccountOrSignOut:autoCreate:attempt',
              context: {'seed': seed},
              stackTrace: st,
            );
            try {
              await selfCreateAccount(seed);
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

  String _seedClinicName() {
    final addr = (email ?? '').trim();
    if (addr.isEmpty) return 'عيادة جديدة';
    final handle = addr.split('@').first;
    return handle.isEmpty ? 'عيادة جديدة' : 'عيادة $handle';
  }

  /// يسمح لمحاولة واحدة فقط لإنشاء حساب تلقائي (مسار onboarding المالك).
  void allowAutoCreateAccountOnce() {
    _allowAutoCreateAccount = true;
    _autoCreateAttempted = false;
  }

  /// يجلب صلاحيات الميزات + CRUD للحساب الحالي ويخزّنها محليًا
  Future<void> _refreshFeaturePermissions() async {
    final accId = accountId;
    if (accId == null || accId.isEmpty) return;
    try {
      final perms = await _auth.fetchMyFeaturePermissions(accountId: accId);
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
      _permissionsLoaded = false;
      _permissionsError = '${e}';
      _allowAllFeatures = false;
      _allowedFeatures = <String>{};
      _canCreate = false;
      _canUpdate = false;
      _canDelete = false;
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
      final list =
      csv.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
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
    await sp.setString(_kUid, currentUser!['uid'] ?? '');
    await sp.setString(_kEmail, currentUser!['email'] ?? '');
    await sp.setString(_kAccountId, currentUser!['accountId'] ?? '');
    await sp.setString(_kRole, (currentUser!['role'] ?? '').toString().toLowerCase());
    await sp.setBool(_kDisabled, currentUser!['disabled'] ?? false);
    await sp.setString(_kPlanCode, (currentUser!['planCode'] ?? 'free').toString().toLowerCase());
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
    final savedDev = sp.getString(_kDeviceId);

    if (uid != null && uid.isNotEmpty) {
      currentUser = {
        'uid': uid,
        'email': sp.getString(_kEmail),
        'accountId': accountId,
        'role': (role ?? '').toLowerCase(),
        'disabled': disabled ?? false,
        'isSuperAdmin': (role ?? '').toLowerCase() == 'superadmin',
        'planCode': (planCode ?? 'free').toLowerCase(),
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
    await sp.remove(_kAccountId);
    await sp.remove(_kRole);
    await sp.remove(_kDisabled);
    await sp.remove(_kPlanCode);
    // لا نحذف _kDeviceId لأنه مُعرّف جهاز ثابت على مستوى الجهاز.

    // نظّف أيضًا الصلاحيات المخزّنة
    await sp.remove(_kAllowedFeatures);
    await sp.remove(_kAllowAllFeatures);
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
        final patientName = (label == null || label.isEmpty) ? 'مريض جديد' : label;
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
    super.dispose();
  }
}
