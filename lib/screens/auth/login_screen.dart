// lib/screens/auth/login_screen.dart
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:nhost_dart/nhost_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/core/auth_role_state.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/network_status_service.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';
import 'package:aelmamclinic/utils/network_error_classifier.dart';
import 'package:aelmamclinic/app/theme/app_colors.dart';
import 'package:aelmamclinic/core/constants/app_spacing.dart';
import 'package:aelmamclinic/core/widgets/brand_header.dart';
import 'package:aelmamclinic/core/widgets/data_surface_widgets.dart';
import 'package:aelmamclinic/widgets/language_switch_button.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/neumorphism.dart';

// 👇 إضافات مهمة
import 'package:aelmamclinic/screens/admin/admin_dashboard_screen.dart';
import 'package:aelmamclinic/screens/statistics/statistics_overview_screen.dart';

enum _PendingLocalWipeAction { wipe, signOut }

enum _PendingLocalWipeOutcome { notNeeded, wiped, signedOut, failed }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  String? _error;
  bool _rememberMe = false;

  UnsubscribeDelegate? _authUnsub;
  bool _navigating = false;
  bool _routeCheckScheduled = false;

  // نضمن تشغيل الـ Bootstrap مرة واحدة عند وجود جلسة مسبقة
  bool _bootstrappedOnce = false;

  static const _rememberMeKey = 'auth.remember_me';
  static const _rememberEmailKey = 'auth.remember_email';
  static const _rememberPassKey = 'auth.remember_pass';

  static const _supportNumbers = <String>['+967780696069', '+967730696069'];

  Future<void> _callNumber(String number) async {
    final uri = Uri.parse('tel:$number');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('auth_open_dialer_failed'))),
      );
    }
  }

  Future<void> _openWhatsApp(String number) async {
    final clean = number.replaceAll('+', '');
    final uri = Uri.parse('https://wa.me/$clean');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('auth_open_whatsapp_failed'))),
      );
    }
  }

  Future<void> _openContactPicker({required bool whatsapp}) async {
    if (!mounted) return;

    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      whatsapp ? Icons.chat_rounded : Icons.phone_rounded,
                      color: whatsapp ? scheme.secondary : scheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        whatsapp
                            ? ctx.tr('auth_pick_whatsapp_number')
                            : ctx.tr('auth_pick_call_number'),
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 6),
                ..._supportNumbers.map((n) {
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      whatsapp ? Icons.chat_rounded : Icons.phone_rounded,
                      color: whatsapp ? scheme.secondary : scheme.primary,
                    ),
                    title: Text(
                      n,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    onTap: () => Navigator.of(ctx).pop(n),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );

    if (selected == null) return;
    if (whatsapp) {
      await _openWhatsApp(selected);
    } else {
      await _callNumber(selected);
    }
  }

  @override
  void initState() {
    super.initState();

    _loadRememberedCredentials();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRouteIfSignedIn();
    });

    _authUnsub = NhostManager.client.auth.addAuthStateChangedCallback((state) {
      if (state == AuthenticationState.signedIn) {
        if (_loading || _navigating) return;
        _checkAndRouteIfSignedIn();
      }
    });
  }

  Future<void> _loadRememberedCredentials() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_rememberPassKey);
      final remember = sp.getBool(_rememberMeKey) ?? false;
      if (!mounted) return;
      final email = remember ? (sp.getString(_rememberEmailKey) ?? '') : '';
      setState(() {
        _rememberMe = remember;
        _email.text = email;
        _pass.clear();
      });
    } catch (_) {}
  }

  Future<void> _persistRememberedCredentials({required String email}) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_rememberMeKey, _rememberMe);
      await sp.remove(_rememberPassKey);
      if (_rememberMe) {
        await sp.setString(_rememberEmailKey, email);
      } else {
        await sp.remove(_rememberEmailKey);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _authUnsub?.call();
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  bool _isValidEmail(String email) {
    final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return re.hasMatch(email);
  }

  Future<AuthSessionResult> _ensurePostLoginState(
    AuthProvider auth, {
    bool expectOwnerOrAdmin = false,
  }) async {
    AuthSessionResult result = await auth.refreshAndValidateCurrentUser();
    if (!result.isSuccess) return result;

    if (auth.isSuperAdmin) return result;

    const int maxAttempts = 6;
    for (int i = 0; i < maxAttempts; i++) {
      final accId = auth.accountId ?? '';
      if (accId.isEmpty) {
        return const AuthSessionResult.noAccount();
      }

      final role = auth.role?.toLowerCase() ?? '';
      if (expectOwnerOrAdmin &&
          (role.isEmpty ||
              (role != 'owner' && role != 'admin' && role != 'superadmin'))) {
        // انتظار تحديث الدور بعد إنشاء الحساب
        await Future.delayed(const Duration(milliseconds: 400));
        result = await auth.refreshAndValidateCurrentUser();
        if (!result.isSuccess) return result;
        continue;
      }

      await auth.refreshPermissions();
      if (auth.permissionsLoaded) {
        return result;
      }
      await Future.delayed(const Duration(milliseconds: 400));
      result = await auth.refreshAndValidateCurrentUser();
      if (!result.isSuccess) return result;
    }

    return result;
  }

  bool _canRouteIntoAppShell(AuthProvider auth) => auth.hasReadyAppShell;

  String _serverUnavailableMessage() =>
      context.trRaw('تعذر الوصول إلى الخادم حاليًا. حاول مرة أخرى بعد قليل.');

  String _postLoginFallbackMessage(AuthProvider auth) {
    if (auth.hasPendingLocalWipe) {
      return _messageForStatus(AuthSessionStatus.isolationRequired) ??
          context.tr('auth_error_account_verification_failed');
    }
    if (auth.needsAccountContextResolution) {
      return context.tr('auth_error_account_create_failed_plain');
    }
    if (auth.isOffline ||
        !NetworkStatusService.instance.isOnline ||
        auth.needsRemoteSessionRecovery) {
      return context.tr('auth_status_network_issue');
    }
    return context.tr('auth_error_account_verification_failed');
  }

  bool _shouldShowAuthenticatedRecovery(AuthProvider auth) =>
      auth.isLoggedIn && !_canRouteIntoAppShell(auth);

  bool _isIsolationRecovery(AuthProvider auth) => auth.hasPendingLocalWipe;

  String _recoveryTitle(AuthProvider auth) {
    if (_isIsolationRecovery(auth)) {
      return context.tr('auth_recovery_isolation_title');
    }
    if (auth.canEnterRemoteAdminShell || auth.isSuperAdmin) {
      return context.trRaw('استعادة جلسة الإدارة');
    }
    if (auth.needsAccountContextResolution) {
      return context.trRaw('إكمال ربط الحساب');
    }
    return context.trRaw('استعادة الجلسة');
  }

  String _recoverySubtitle(AuthProvider auth) {
    if (_isIsolationRecovery(auth)) {
      return context.tr('auth_recovery_isolation_subtitle');
    }
    if (auth.canEnterRemoteAdminShell || auth.isSuperAdmin) {
      return context.trRaw(
        'تم العثور على جلسة محلية للمشرف، لكن لوحة الإدارة تحتاج جلسة خادم صالحة قبل المتابعة.',
      );
    }
    if (auth.needsAccountContextResolution) {
      return context.trRaw(
        'تم تسجيل الدخول، لكن لم يتم تثبيت حساب العيادة الحالي بعد. يمكنك إعادة التحقق أو إكمال بيانات المرفق الصحي.',
      );
    }
    if (auth.needsRemoteSessionRecovery) {
      return context.trRaw(
        'الجلسة المحلية ما زالت موجودة، وسيتم استعادة جلسة الخادم في الخلفية عند توفر الاتصال.',
      );
    }
    return context.trRaw('هناك تحقق إضافي مطلوب قبل فتح التطبيق بالكامل.');
  }

  IconData _recoveryIcon(AuthProvider auth) {
    if (_isIsolationRecovery(auth)) {
      return Icons.delete_sweep_rounded;
    }
    if (auth.needsAccountContextResolution) {
      return Icons.domain_verification_rounded;
    }
    return Icons.sync_problem_rounded;
  }

  Future<_PendingLocalWipeOutcome> _resolvePendingLocalWipe(
    AuthProvider auth, {
    bool refreshState = true,
    bool rebootstrap = true,
  }) async {
    if (refreshState) {
      await auth.refreshPendingLocalWipeState();
    }
    if (!mounted || !auth.hasPendingLocalWipe) {
      return _PendingLocalWipeOutcome.notNeeded;
    }

    final autoOk = await auth.performPendingLocalWipe(
      createBackup: true,
      rebootstrap: rebootstrap,
    );
    if (!mounted) {
      return autoOk
          ? _PendingLocalWipeOutcome.wiped
          : _PendingLocalWipeOutcome.failed;
    }
    if (autoOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('auth_pending_wipe_success'))),
      );
      return _PendingLocalWipeOutcome.wiped;
    }

    final pendingAcc = auth.pendingWipeAccountId ?? '';
    final currentAcc = auth.accountId ?? '';
    final different = pendingAcc.isNotEmpty &&
        currentAcc.isNotEmpty &&
        pendingAcc != currentAcc;
    final message = different
        ? context.tr('auth_confirm_switch_different_account')
        : context.tr('auth_confirm_switch_stale_local_data');

    final action = await showDialog<_PendingLocalWipeAction>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('auth_confirm_switch_title')),
        content: Text(message, textAlign: TextAlign.start),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(_PendingLocalWipeAction.signOut),
            child: Text(context.tr('common_logout')),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.of(ctx).pop(_PendingLocalWipeAction.wipe),
            child: Text(context.tr('auth_action_backup_and_wipe_now')),
          ),
        ],
      ),
    );

    if (action == _PendingLocalWipeAction.signOut) {
      await auth.signOut();
      return _PendingLocalWipeOutcome.signedOut;
    }
    if (action != _PendingLocalWipeAction.wipe) {
      return _PendingLocalWipeOutcome.failed;
    }

    final ok = await auth.performPendingLocalWipe(
      createBackup: true,
      rebootstrap: rebootstrap,
    );
    if (!mounted) {
      return ok
          ? _PendingLocalWipeOutcome.wiped
          : _PendingLocalWipeOutcome.failed;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr(
            ok ? 'auth_pending_wipe_success' : 'auth_pending_wipe_failed',
          ),
        ),
      ),
    );
    if (!ok) {
      setState(() {
        _error = context.tr('auth_status_local_isolation_required');
      });
    }
    return ok
        ? _PendingLocalWipeOutcome.wiped
        : _PendingLocalWipeOutcome.failed;
  }

  Future<void> _retryAuthenticatedRecovery(AuthProvider auth) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (auth.hasPendingLocalWipe) {
        final outcome = await _resolvePendingLocalWipe(
          auth,
          refreshState: false,
        );
        if (!mounted) return;
        if (outcome == _PendingLocalWipeOutcome.wiped) {
          await _checkAndRouteIfSignedIn(force: true);
        }
        return;
      }
      final result = await auth.reconcileAuthenticatedSession(
        reason: 'login_recovery',
        bootstrapOnSuccess: true,
        bootstrapPull: true,
        resumeSyncOnSuccess: true,
      );
      if (!mounted) return;
      if (result.status == AuthSessionStatus.isolationRequired ||
          auth.hasPendingLocalWipe) {
        final outcome = await _resolvePendingLocalWipe(
          auth,
          refreshState: false,
        );
        if (!mounted) return;
        if (outcome == _PendingLocalWipeOutcome.wiped) {
          await _checkAndRouteIfSignedIn(force: true);
        }
        return;
      }
      if (result.isSuccess) {
        await _checkAndRouteIfSignedIn(force: true);
        return;
      }
      setState(() {
        _error = _messageForStatus(result.status) ??
            context.tr('auth_error_account_verification_failed');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _mapLoginError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _completeAuthenticatedAccountSetup(AuthProvider auth) async {
    if (_loading || auth.isSuperAdmin) return;
    final clinicProfile = await _askClinicProfile();
    if (clinicProfile == null) {
      if (!mounted) return;
      setState(() => _error = context.tr('auth_error_clinic_name_required'));
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    Object? createError;
    try {
      auth.setPendingClinicProfile(clinicProfile);
      try {
        await auth.selfCreateAccount(clinicProfile);
        auth.clearOwnerOnboardingState();
      } catch (e) {
        auth.clearOwnerOnboardingState();
        createError = e;
      }
      await auth.refreshSession();
      final result = await auth.reconcileAuthenticatedSession(
        reason: 'login_complete_account',
        bootstrapOnSuccess: true,
        bootstrapPull: true,
        resumeSyncOnSuccess: true,
      );
      if (!mounted) return;
      if (result.status == AuthSessionStatus.isolationRequired ||
          auth.hasPendingLocalWipe) {
        final outcome = await _resolvePendingLocalWipe(
          auth,
          refreshState: false,
        );
        if (!mounted) return;
        if (outcome == _PendingLocalWipeOutcome.wiped) {
          await _checkAndRouteIfSignedIn(force: true);
        }
        return;
      }
      if (!result.isSuccess) {
        final fallback = _messageForStatus(result.status) ??
            context.tr('auth_error_account_verification_failed');
        setState(() {
          _error = createError != null
              ? context.tr(
                  'auth_error_account_create_failed_with_reason',
                  params: {'reason': _mapLoginError(createError)},
                )
              : fallback;
        });
        return;
      }
      await _ensureClinicProfileComplete(auth);
      await _checkAndRouteIfSignedIn(force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = context.tr(
          'auth_error_account_create_failed_with_reason',
          params: {'reason': _mapLoginError(e)},
        );
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// يقرر التوجيه حسب المستخدم الحالي (سوبر أدمن أو لا) ويضمن تشغيل المزامنة.
  Future<void> _checkAndRouteIfSignedIn({bool force = false}) async {
    if (_navigating || (!force && _loading) || !mounted) return;

    final authProv = context.read<AuthProvider>();
    if (!authProv.isLoggedIn) return;

    if (force || !_canRouteIntoAppShell(authProv)) {
      final result = await authProv.reconcileAuthenticatedSession(
        reason: force ? 'login_route_force' : 'login_route',
        bootstrapOnSuccess: true,
        bootstrapPull: false,
        resumeSyncOnSuccess: true,
      );
      if (!mounted) return;
      if (!result.isSuccess) {
        final allowContinue =
            result.status == AuthSessionStatus.planUpgradeRequired &&
                (() {
                  final role = authProv.role?.toLowerCase();
                  return role == 'owner' || role == 'admin';
                })();
        if (!allowContinue) {
          final message = _messageForStatus(result.status);
          if (message != null) {
            setState(() {
              _error = message;
              _loading = false;
            });
          }
          return;
        }
      }

      if (result.status == AuthSessionStatus.isolationRequired ||
          authProv.hasPendingLocalWipe) {
        setState(() {
          _error = _messageForStatus(AuthSessionStatus.isolationRequired);
          _loading = false;
        });
        return;
      }
    }

    final hasReadyShell = _canRouteIntoAppShell(authProv);
    if (!hasReadyShell) {
      if (!mounted) return;
      setState(() {
        _error = _postLoginFallbackMessage(authProv);
        _loading = false;
      });
      return;
    }

    if (!_bootstrappedOnce) {
      if (authProv.canEnterClinicShell) {
        await _ensureClinicProfileComplete(authProv);
        await authProv.bootstrapSync(
          pull: false,
          realtime: true,
          enableLogs: kDebugMode,
          debounce: const Duration(seconds: 1),
        );
      }
      _bootstrappedOnce = true;
    }

    if (authProv.hasPendingLocalWipe || !_canRouteIntoAppShell(authProv)) {
      if (!mounted) return;
      setState(() {
        _error = _postLoginFallbackMessage(authProv);
        _loading = false;
      });
      return;
    }

    _navigating = true;
    if (!mounted) return;

    if (authProv.canEnterRemoteAdminShell) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const StatisticsOverviewScreen()),
      );
    }
  }

  Future<void> _submit(AuthProvider auth) async {
    if (_loading) return;

    FocusScope.of(context).unfocus();

    final email = _email.text.trim();
    final pass = _pass.text.trim();

    if (email.isEmpty || pass.isEmpty) {
      setState(
        () => _error = context.tr('auth_error_enter_email_and_password'),
      );
      return;
    }
    if (!_isValidEmail(email) || pass.length < 9) {
      setState(() => _error = context.tr('auth_error_password_policy'));
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final signInResp = await auth.signIn(email, pass);
      if (signInResp.session == null) {
        // Fallback: sometimes SDK returns null session while token is present.
        final token = auth.accessToken;
        if (token == null || token.isEmpty) {
          setState(
            () => _error = context.tr('auth_error_login_activation_needed'),
          );
          return;
        }
      }
      await _persistRememberedCredentials(email: email);

      // Ensure stale superadmin header does not leak into user session.
      AuthRoleState.clear();
      NhostGraphqlService.refreshClient();

      var result = await _ensurePostLoginState(auth);
      if (!mounted) return;

      // لا نستخدم roles/defaultRole الخام لتحديد مسار السوبر أدمن.
      // AuthProvider/NhostAuthService يتحققان من الخادم أولًا. أي حساب عيادة
      // يحمل claim superadmin قديمًا يجب أن يمر بمسار العيادة أو onboarding.
      if (result.status == AuthSessionStatus.noAccount) {
        if (auth.isSuperAdmin) {
          result = const AuthSessionResult.success();
        } else {
          final clinicProfile = await _askClinicProfile();
          if (clinicProfile == null) {
            setState(
              () => _error = context.tr('auth_error_clinic_name_required'),
            );
            return;
          }
          auth.setPendingClinicProfile(clinicProfile);
          Object? createError;
          try {
            await auth.selfCreateAccount(clinicProfile);
            auth.clearOwnerOnboardingState();
          } catch (e) {
            auth.clearOwnerOnboardingState();
            createError = e;
          }
          try {
            await auth.refreshSession();
          } catch (e) {
            createError ??= e;
          }
          final recheck = await _ensurePostLoginState(auth);
          if (!mounted) return;
          if (!recheck.isSuccess) {
            final base = _messageForStatus(recheck.status) ??
                context.tr('auth_error_account_verification_failed');
            if (createError != null) {
              final mapped = _mapLoginError(createError);
              setState(
                () => _error = context.tr(
                  'auth_error_account_create_failed_with_reason',
                  params: {'reason': mapped},
                ),
              );
            } else {
              setState(() => _error = base);
            }
            return;
          }
          result = recheck;
        }
      }

      if (!result.isSuccess) {
        if (result.status == AuthSessionStatus.planUpgradeRequired) {
          final role = auth.role?.toLowerCase();
          if (role == 'owner' || role == 'admin') {
            // owners/admins can upgrade from داخل التطبيق.
          } else {
            await auth.signOut();
            final message = _messageForStatus(result.status) ??
                context.tr('auth_error_account_verification_failed');
            setState(() => _error = message);
            return;
          }
        } else if (result.status == AuthSessionStatus.noAccount) {
          final message = _messageForStatus(result.status) ??
              context.tr('auth_error_account_verification_failed');
          setState(() => _error = message);
          return;
        } else {
          final message = _messageForStatus(result.status) ??
              context.tr('auth_error_account_verification_failed');
          setState(() => _error = message);
          return;
        }
      }

      if (!auth.isSuperAdmin && (auth.accountId ?? '').isEmpty) {
        setState(
          () => _error = context.tr('auth_error_account_create_failed_plain'),
        );
        return;
      }

      final preBootstrapIsolation = await _resolvePendingLocalWipe(
        auth,
        rebootstrap: false,
      );
      if (!mounted) return;
      if (preBootstrapIsolation == _PendingLocalWipeOutcome.signedOut ||
          preBootstrapIsolation == _PendingLocalWipeOutcome.failed) {
        return;
      }

      await _ensureClinicProfileComplete(auth);

      if (auth.isLoggedIn) {
        await auth.bootstrapSync(
          pull: true,
          realtime: true,
          enableLogs: kDebugMode,
          debounce: const Duration(seconds: 1),
        );
        _bootstrappedOnce = true;
      }

      final postBootstrapIsolation = await _resolvePendingLocalWipe(auth);
      if (!mounted) return;
      if (postBootstrapIsolation == _PendingLocalWipeOutcome.signedOut ||
          postBootstrapIsolation == _PendingLocalWipeOutcome.failed) {
        return;
      }

      await _checkAndRouteIfSignedIn(force: true);
    } catch (e) {
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint('[LOGIN] signIn failed: $e');
      }
      setState(() => _error = _mapLoginError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signUp(AuthProvider auth) async {
    if (_loading) return;
    FocusScope.of(context).unfocus();

    final email = _email.text.trim();
    final pass = _pass.text.trim();
    if (email.isEmpty || pass.isEmpty) {
      setState(
        () => _error = context.tr('auth_error_enter_email_and_password_first'),
      );
      return;
    }
    if (!_isValidEmail(email) || pass.length < 9) {
      setState(() => _error = context.tr('auth_error_password_policy'));
      return;
    }

    final clinicProfile = await _askClinicProfile();
    if (clinicProfile == null) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    var shouldCleanupAuthSession = false;
    var signupCompleted = false;
    var recoveredExistingEmail = false;
    try {
      if (auth.hasLocalSession || auth.hasNhostSession) {
        await auth.signOut();
        AuthRoleState.clear();
        NhostGraphqlService.refreshClient();
      }
      auth.setPendingClinicProfile(clinicProfile);
      auth.allowAutoCreateAccountOnce();
      dynamic signUpResp;
      try {
        signUpResp = await auth.signUp(
          email,
          pass,
          locale: context.currentLocaleCode,
        );
      } catch (e) {
        if (!_isEmailAlreadyInUseError(e)) rethrow;
        recoveredExistingEmail = true;
        try {
          signUpResp = await auth.signIn(email, pass);
        } catch (signInError) {
          if (!mounted) return;
          setState(() {
            _error = _isInvalidCredentialsError(signInError)
                ? context.tr('auth_error_email_already_in_use')
                : _mapLoginError(signInError);
          });
          return;
        }
      }
      if (signUpResp.session == null) {
        if (!recoveredExistingEmail) {
          try {
            signUpResp = await auth.signIn(email, pass);
          } catch (_) {}
        }
        if (signUpResp.session == null) {
          final token = auth.accessToken;
          if (token != null && token.isNotEmpty) {
            // Continue; token exists even if session is null.
          } else {
            setState(
              () => _error = recoveredExistingEmail
                  ? context.tr('auth_error_login_activation_needed')
                  : context.tr('auth_error_signup_verify_email'),
            );
            return;
          }
        }
      }
      shouldCleanupAuthSession = auth.hasLocalSession ||
          auth.hasNhostSession ||
          ((auth.accessToken ?? '').isNotEmpty);
      await _persistRememberedCredentials(email: email);
      // Ensure stale superadmin header does not leak into user session.
      AuthRoleState.clear();
      NhostGraphqlService.refreshClient();
      var result = await _ensurePostLoginState(auth, expectOwnerOrAdmin: true);
      if (!mounted) return;
      if (result.status == AuthSessionStatus.noAccount) {
        Object? createError;
        try {
          await auth.selfCreateAccount(clinicProfile);
          auth.clearOwnerOnboardingState();
        } catch (e) {
          auth.clearOwnerOnboardingState();
          createError = e;
        }
        try {
          await auth.refreshSession();
        } catch (e) {
          createError ??= e;
        }
        result = await _ensurePostLoginState(auth, expectOwnerOrAdmin: true);
        if (!mounted) return;
        if (!result.isSuccess) {
          final message = createError != null
              ? context.tr(
                  'auth_error_account_create_failed_with_reason',
                  params: {'reason': _mapLoginError(createError)},
                )
              : (_messageForStatus(result.status) ??
                  context.tr('auth_error_account_verification_failed'));
          setState(() => _error = message);
          return;
        }
      }
      if (!mounted) return;
      if (!result.isSuccess) {
        final message = _messageForStatus(result.status) ??
            context.tr('auth_error_account_verification_failed');
        setState(() => _error = message);
        return;
      }
      final role = auth.role?.toLowerCase() ?? '';
      if (!auth.isSuperAdmin &&
          role != 'owner' &&
          role != 'admin' &&
          role != 'superadmin') {
        setState(
          () => _error = context.tr('auth_error_account_type_undetermined'),
        );
        return;
      }
      if (!auth.isSuperAdmin && (auth.accountId ?? '').isEmpty) {
        setState(
          () => _error = context.tr('auth_error_account_create_failed_plain'),
        );
        return;
      }

      final preBootstrapIsolation = await _resolvePendingLocalWipe(
        auth,
        rebootstrap: false,
      );
      if (!mounted) return;
      if (preBootstrapIsolation == _PendingLocalWipeOutcome.signedOut ||
          preBootstrapIsolation == _PendingLocalWipeOutcome.failed) {
        return;
      }

      await _ensureClinicProfileComplete(auth);

      await auth.bootstrapSync(
        pull: true,
        realtime: true,
        enableLogs: kDebugMode,
        debounce: const Duration(seconds: 1),
      );
      _bootstrappedOnce = true;

      final postBootstrapIsolation = await _resolvePendingLocalWipe(auth);
      if (!mounted) return;
      if (postBootstrapIsolation == _PendingLocalWipeOutcome.signedOut ||
          postBootstrapIsolation == _PendingLocalWipeOutcome.failed) {
        return;
      }

      await _checkAndRouteIfSignedIn(force: true);
      signupCompleted = true;
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = context.tr(
          'auth_error_signup_failed_with_reason',
          params: {'reason': e},
        ),
      );
    } finally {
      if (!signupCompleted) {
        auth.clearOwnerOnboardingState();
      }
      if (!signupCompleted && shouldCleanupAuthSession) {
        try {
          await auth.signOut();
        } catch (_) {}
        AuthRoleState.clear();
        NhostGraphqlService.refreshClient();
      }
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<ClinicProfileInput?> _askClinicProfile() async {
    final isEnglish = Localizations.localeOf(
      context,
    ).languageCode.toLowerCase().startsWith('en');
    final arStep = await _askClinicProfileStep(
      title: context.trRaw('بيانات المرفق الصحي (عربي)'),
      nameLabel: isEnglish ? 'Clinic name (Arabic)' : 'اسم المرفق الصحي',
      cityLabel: isEnglish ? 'City (Arabic)' : 'المدينة',
      streetLabel: isEnglish ? 'Street (Arabic)' : 'الشارع',
      nearLabel: isEnglish ? 'Near (Arabic)' : 'بجوار',
      phoneLabel: isEnglish ? 'Phone number' : 'رقم الهاتف',
      phone2Label: isEnglish
          ? 'Additional phone (optional)'
          : 'رقم هاتف إضافي (اختياري)',
      prefillPhone: null,
      prefillPhone2: null,
    );
    if (arStep == null) return null;

    final enStep = await _askClinicProfileStep(
      title: 'Clinic Info (English)',
      nameLabel: 'Clinic name',
      cityLabel: 'City',
      streetLabel: 'Street',
      nearLabel: 'Near',
      phoneLabel: 'Phone',
      phone2Label: 'Phone 2 (optional)',
      prefillPhone: arStep.phone,
      prefillPhone2: arStep.phone2,
    );
    if (enStep == null) return null;

    return ClinicProfileInput(
      nameAr: arStep.name,
      cityAr: arStep.city,
      streetAr: arStep.street,
      nearAr: arStep.near,
      nameEn: enStep.name,
      cityEn: enStep.city,
      streetEn: enStep.street,
      nearEn: enStep.near,
      phone: arStep.phone,
      phone2: arStep.phone2,
    );
  }

  Future<void> _ensureClinicProfileComplete(AuthProvider auth) async {
    if (!mounted) return;
    try {
      if (auth.isSuperAdmin) return;
      if ((auth.accountId ?? '').trim().isEmpty) return;
      final complete = await ClinicProfileService.isProfileComplete();
      if (complete) return;
      final profile = await _askClinicProfile();
      if (profile == null) return;
      await auth.updateClinicProfile(profile);
      await auth.refreshAndValidateCurrentUser();
    } catch (_) {}
  }

  Future<_ClinicProfileStep?> _askClinicProfileStep({
    required String title,
    required String nameLabel,
    required String cityLabel,
    required String streetLabel,
    required String nearLabel,
    required String phoneLabel,
    required String phone2Label,
    String? prefillPhone,
    String? prefillPhone2,
  }) async {
    final nameCtrl = TextEditingController();
    final cityCtrl = TextEditingController();
    final streetCtrl = TextEditingController();
    final nearCtrl = TextEditingController();
    final phoneCtrl = TextEditingController(text: prefillPhone ?? '');
    final phone2Ctrl = TextEditingController(text: prefillPhone2 ?? '');

    final isEnglish = title.toLowerCase().contains('english') ||
        title.toLowerCase().contains('clinic');

    final result = await showDialog<_ClinicProfileStep>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;

        InputDecoration dec(String label, IconData icon) {
          return InputDecoration(
            labelText: label,
            prefixIcon: Icon(icon),
            filled: true,
            fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.55),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.55),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: scheme.primary.withValues(alpha: 0.9),
                width: 1.2,
              ),
            ),
          );
        }

        return Directionality(
          textDirection: isEnglish ? TextDirection.ltr : TextDirection.rtl,
          child: Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 22,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            scheme.surface,
                            scheme.surfaceContainerHighest.withValues(
                              alpha: 0.75,
                            ),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: -60,
                    right: -60,
                    child: _BlurBlob(
                      size: 180,
                      color: scheme.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _NeoIconBadge(
                              icon: Icons.assignment_rounded,
                              size: 44,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w900,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isEnglish
                                        ? 'Please fill all fields to complete account setup.'
                                        : 'يرجى تعبئة جميع الحقول لإكمال إنشاء الحساب.',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: scheme.onSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: nameCtrl,
                          decoration: dec(
                            nameLabel,
                            Icons.local_hospital_rounded,
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: cityCtrl,
                          decoration: dec(
                            cityLabel,
                            Icons.location_city_rounded,
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: streetCtrl,
                          decoration: dec(streetLabel, Icons.signpost_rounded),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: nearCtrl,
                          decoration: dec(nearLabel, Icons.place_rounded),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: phoneCtrl,
                          decoration: dec(phoneLabel, Icons.phone_rounded),
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.done,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: phone2Ctrl,
                          decoration: dec(
                            phone2Label,
                            Icons.phone_forwarded_rounded,
                          ),
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.done,
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: Text(isEnglish ? 'Cancel' : 'إلغاء'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                onPressed: () {
                                  final name = nameCtrl.text.trim();
                                  final city = cityCtrl.text.trim();
                                  final street = streetCtrl.text.trim();
                                  final near = nearCtrl.text.trim();
                                  final phone = phoneCtrl.text.trim();
                                  final phone2 = phone2Ctrl.text.trim();
                                  if (name.isEmpty ||
                                      city.isEmpty ||
                                      street.isEmpty ||
                                      near.isEmpty ||
                                      phone.isEmpty) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          isEnglish
                                              ? 'Please fill all fields.'
                                              : context.trRaw(
                                                  'يرجى تعبئة جميع الحقول.',
                                                ),
                                        ),
                                      ),
                                    );
                                    return;
                                  }
                                  Navigator.of(ctx).pop(
                                    _ClinicProfileStep(
                                      name: name,
                                      city: city,
                                      street: street,
                                      near: near,
                                      phone: phone,
                                      phone2: phone2.isEmpty ? null : phone2,
                                    ),
                                  );
                                },
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: Text(isEnglish ? 'Continue' : 'متابعة'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    nameCtrl.dispose();
    cityCtrl.dispose();
    streetCtrl.dispose();
    nearCtrl.dispose();
    phoneCtrl.dispose();
    return result;
  }

  String? _messageForStatus(AuthSessionStatus status) {
    switch (status) {
      case AuthSessionStatus.success:
        return null;
      case AuthSessionStatus.isolationRequired:
        return context.tr('auth_status_local_isolation_required');
      case AuthSessionStatus.disabled:
        return context.tr('auth_status_disabled_contact_admin');
      case AuthSessionStatus.accountFrozen:
        return context.tr('auth_status_account_frozen');
      case AuthSessionStatus.noAccount:
        return context.tr('auth_status_removed_from_management');
      case AuthSessionStatus.planUpgradeRequired:
        return context.tr('auth_status_plan_upgrade_required');
      case AuthSessionStatus.signedOut:
        return context.tr('auth_status_session_ended');
      case AuthSessionStatus.networkError:
        return context.tr('auth_status_network_issue');
      case AuthSessionStatus.unknown:
        return context.tr('auth_status_unknown');
    }
  }

  bool _isInvalidCredentialsError(Object error) {
    if (error is ApiException) {
      final status = error.statusCode;
      final body = (error.responseBody ?? '').toString().toLowerCase();
      if (status == 401 ||
          body.contains('invalid-email-password') ||
          body.contains('incorrect email or password')) {
        return true;
      }
    }
    final lower = error.toString().toLowerCase();
    return lower.contains('invalid-email-password') ||
        lower.contains('incorrect email or password') ||
        lower.contains('statuscode=401') ||
        lower.contains('status: 401');
  }

  bool _isInvalidEmailError(Object error) {
    if (error is ApiException) {
      final body = (error.responseBody ?? '').toString().toLowerCase();
      if (body.contains('invalid-email') ||
          body.contains('email format') ||
          body.contains('bad email')) {
        return true;
      }
    }
    final lower = error.toString().toLowerCase();
    return lower.contains('invalid-email') ||
        lower.contains('email format') ||
        lower.contains('bad email');
  }

  bool _isEmailAlreadyInUseError(Object error) {
    if (error is ApiException) {
      final status = error.statusCode;
      final body = (error.responseBody ?? '').toString().toLowerCase();
      if (status == 409 &&
          (body.contains('email-already-in-use') ||
              body.contains('email already in use'))) {
        return true;
      }
    }
    final lower = error.toString().toLowerCase();
    return lower.contains('email-already-in-use') ||
        lower.contains('email already in use');
  }

  String _mapLoginError(Object error) {
    if (_isEmailAlreadyInUseError(error)) {
      return context.tr('auth_error_email_already_in_use');
    }
    if (_isInvalidCredentialsError(error)) {
      return context.tr('auth_error_invalid_credentials');
    }
    if (_isInvalidEmailError(error)) {
      return context.tr('auth_error_invalid_email');
    }
    if (error is ApiException) {
      final status = error.statusCode;
      if (status >= 500 ||
          NetworkErrorClassifier.isServerUnavailableLikeMessage(
            error.toString(),
          )) {
        return _serverUnavailableMessage();
      }
    }
    if (NetworkErrorClassifier.isTransportError(error)) {
      return context.tr('auth_error_network_unstable');
    }
    final lower = error.toString().toLowerCase();
    if (NetworkErrorClassifier.isTransportLikeMessage(lower)) {
      return context.tr('auth_error_network_unstable');
    }
    if (lower.contains('no stream event') ||
        NetworkErrorClassifier.isServerUnavailableLikeMessage(lower)) {
      return _serverUnavailableMessage();
    }
    return context.tr('auth_error_login_failed');
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;
    final showRecovery = _shouldShowAuthenticatedRecovery(auth);

    if (!_routeCheckScheduled && _canRouteIntoAppShell(auth)) {
      _routeCheckScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          await _checkAndRouteIfSignedIn(force: true);
        } finally {
          _routeCheckScheduled = false;
        }
      });
    }

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[
              AppColors.surfaceRaised,
              AppColors.background,
              AppColors.primarySoft,
            ],
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              PositionedDirectional(
                top: AppSpacing.sm,
                end: AppSpacing.sm,
                child: AppSoftCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: AppSpacing.xxs,
                  ),
                  radius: 18,
                  child: const LanguageSwitchButton(),
                ),
              ),
              Center(
                child: SingleChildScrollView(
                  padding: AppSpacing.responsivePagePadding(context),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppSoftCard(
                          radius: 30,
                          padding: AppSpacing.responsivePagePadding(context),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const BrandHeader(),
                              const SizedBox(height: AppSpacing.lg),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: AppStatusChip(
                                  label: showRecovery
                                      ? context.trRaw('استعادة جلسة')
                                      : context.trRaw('دخول آمن'),
                                  tone: showRecovery
                                      ? AppTone.warning
                                      : AppTone.primary,
                                  icon: showRecovery
                                      ? Icons.sync_problem_rounded
                                      : Icons.verified_user_rounded,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                              Text(
                                showRecovery
                                    ? _recoveryTitle(auth)
                                    : context.tr('auth_login_title'),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                showRecovery
                                    ? _recoverySubtitle(auth)
                                    : context.tr('auth_login_subtitle'),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: AppColors.textSecondary,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(height: AppSpacing.lg),
                              if (showRecovery) ...[
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerHighest
                                        .withValues(alpha: 0.45),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: scheme.outlineVariant.withValues(
                                        alpha: 0.35,
                                      ),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            _recoveryIcon(auth),
                                            color: scheme.primary,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              _recoveryTitle(auth),
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 14.5,
                                                color: scheme.onSurface,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      if ((auth.email ?? '').trim().isNotEmpty)
                                        Text(
                                          auth.email!.trim(),
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            color: scheme.onSurface.withValues(
                                              alpha: 0.82,
                                            ),
                                          ),
                                        ),
                                      if ((auth.email ?? '').trim().isNotEmpty)
                                        const SizedBox(height: 8),
                                      Text(
                                        '${context.trRaw('حالة الجلسة')}: ${auth.sessionTopologyState}',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                          color: scheme.onSurface.withValues(
                                            alpha: 0.58,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ] else ...[
                                NeuField(
                                  controller: _email,
                                  labelText: context.tr('auth_email_label'),
                                  keyboardType: TextInputType.emailAddress,
                                  textInputAction: TextInputAction.next,
                                  prefix: const Icon(
                                    Icons.alternate_email_rounded,
                                  ),
                                  onChanged: (_) {
                                    if (_error != null) {
                                      setState(() => _error = null);
                                    }
                                  },
                                ),
                                const SizedBox(height: 12),
                                NeuField(
                                  controller: _pass,
                                  labelText: context.tr('auth_password_label'),
                                  obscureText: _obscure,
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) => _submit(auth),
                                  prefix: const Icon(
                                    Icons.lock_outline_rounded,
                                  ),
                                  suffix: IconButton(
                                    icon: Icon(
                                      _obscure
                                          ? Icons.visibility_rounded
                                          : Icons.visibility_off_rounded,
                                    ),
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                    tooltip: _obscure
                                        ? context.tr('common_show')
                                        : context.tr('common_hide'),
                                  ),
                                  onChanged: (_) {
                                    if (_error != null) {
                                      setState(() => _error = null);
                                    }
                                  },
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  context.tr('auth_password_policy_hint'),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 11,
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Checkbox(
                                      value: _rememberMe,
                                      onChanged: (v) => setState(
                                        () => _rememberMe = v ?? false,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        context.tr('auth_remember_me'),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: scheme.onSurface.withValues(
                                            alpha: 0.80,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (_error != null) ...[
                                const SizedBox(height: 8),
                                _ErrorBanner(text: _error!),
                              ],
                              const SizedBox(height: 12),
                              if (showRecovery) ...[
                                if (auth.hasPendingLocalWipe) ...[
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    width: double.infinity,
                                    child: NeuButton.primary(
                                      label: context.tr(
                                        'auth_action_backup_and_wipe_now',
                                      ),
                                      leading: _loading
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.4,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                        Color>(Colors.white),
                                              ),
                                            )
                                          : const Icon(
                                              Icons.delete_sweep_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.max,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                        vertical: 16,
                                      ),
                                      onPressed: _loading
                                          ? null
                                          : () async {
                                              final outcome =
                                                  await _resolvePendingLocalWipe(
                                                auth,
                                                refreshState: false,
                                              );
                                              if (!mounted) return;
                                              if (outcome ==
                                                  _PendingLocalWipeOutcome
                                                      .wiped) {
                                                await _checkAndRouteIfSignedIn(
                                                  force: true,
                                                );
                                              }
                                            },
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  TextButton(
                                    onPressed:
                                        _loading ? null : () => auth.signOut(),
                                    child: Text(context.tr('common_logout')),
                                  ),
                                ] else ...[
                                  SizedBox(
                                    width: double.infinity,
                                    child: NeuButton.primary(
                                      label: auth.needsAccountContextResolution
                                          ? context.trRaw(
                                              'إعادة التحقق من الحساب',
                                            )
                                          : context.tr('common_retry_now'),
                                      leading: _loading
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.4,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                        Color>(Colors.white),
                                              ),
                                            )
                                          : const Icon(
                                              Icons.sync_rounded,
                                              color: Colors.white,
                                              size: 20,
                                            ),
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.max,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                        vertical: 16,
                                      ),
                                      onPressed: _loading
                                          ? null
                                          : () => _retryAuthenticatedRecovery(
                                                auth,
                                              ),
                                    ),
                                  ),
                                  if (!auth.isSuperAdmin &&
                                      auth.needsAccountContextResolution) ...[
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      width: double.infinity,
                                      child: NeuButton.flat(
                                        label: context.trRaw(
                                          'إكمال إنشاء الحساب',
                                        ),
                                        icon: Icons.apartment_rounded,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        mainAxisSize: MainAxisSize.max,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 14,
                                        ),
                                        onPressed: _loading
                                            ? null
                                            : () =>
                                                _completeAuthenticatedAccountSetup(
                                                  auth,
                                                ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  TextButton(
                                    onPressed:
                                        _loading ? null : () => auth.signOut(),
                                    child: Text(context.tr('common_logout')),
                                  ),
                                ],
                              ] else ...[
                                SizedBox(
                                  width: double.infinity,
                                  child: NeuButton.primary(
                                    label: context.tr('auth_login_button'),
                                    leading: _loading
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2.4,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                Colors.white,
                                              ),
                                            ),
                                          )
                                        : const Icon(
                                            Icons.login_rounded,
                                            color: Colors.white,
                                            size: 20,
                                          ),
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.max,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 16,
                                    ),
                                    onPressed:
                                        _loading ? null : () => _submit(auth),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  child: NeuButton.flat(
                                    label: context.tr('auth_signup_button'),
                                    icon: Icons.person_add_alt_1_rounded,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.max,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 14,
                                    ),
                                    onPressed:
                                        _loading ? null : () => _signUp(auth),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        _SupportBar(
                          onCall: _loading
                              ? null
                              : () => _openContactPicker(whatsapp: false),
                          onWhatsApp: _loading
                              ? null
                              : () => _openContactPicker(whatsapp: true),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlurBlob extends StatelessWidget {
  const _BlurBlob({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _AnimatedBubbleBackdrop extends StatefulWidget {
  const _AnimatedBubbleBackdrop({required this.scheme});
  final ColorScheme scheme;

  @override
  State<_AnimatedBubbleBackdrop> createState() =>
      _AnimatedBubbleBackdropState();
}

class _AnimatedBubbleBackdropState extends State<_AnimatedBubbleBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_BubbleParticle> _bubbles;
  Size _size = Size.zero;
  Duration? _lastTick;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _bubbles = _createBubbles(widget.scheme);
    _controller.addListener(_tick);
  }

  @override
  void didUpdateWidget(covariant _AnimatedBubbleBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scheme != widget.scheme) {
      _bubbles.clear();
      _bubbles.addAll(_createBubbles(widget.scheme));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_BubbleParticle> _createBubbles(ColorScheme scheme) {
    final rng = math.Random(42);
    return List.generate(28, (i) {
      final radius = 11 + rng.nextDouble() * 14;
      final x = rng.nextDouble();
      final y = rng.nextDouble();
      final speed = 8 + rng.nextDouble() * 14;
      final angle = rng.nextDouble() * math.pi * 2;
      final vx = math.cos(angle) * speed;
      final vy = math.sin(angle) * speed;
      final color = (i % 3 == 0
              ? scheme.primary
              : (i % 3 == 1 ? scheme.secondary : scheme.tertiary))
          .withValues(alpha: 0.18);
      return _BubbleParticle(
        pos: Offset(x, y),
        vel: Offset(vx, vy),
        radius: radius,
        color: color,
      );
    });
  }

  void _ensureSize(Size size) {
    if (_size == size || size.isEmpty) return;
    _size = size;
    for (final b in _bubbles) {
      if (!b.initialized) {
        b.pos = Offset(b.pos.dx * _size.width, b.pos.dy * _size.height);
        b.initialized = true;
      }
    }
  }

  void _tick() {
    if (!mounted || _size.isEmpty) return;
    final elapsed = _controller.lastElapsedDuration;
    if (elapsed == null) return;
    final last = _lastTick ?? elapsed;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0) return;
    _step(dt.clamp(0.0, 0.05));
  }

  void _step(double dt) {
    // Update positions
    for (final b in _bubbles) {
      b.pos = Offset(b.pos.dx + b.vel.dx * dt, b.pos.dy + b.vel.dy * dt);

      // Wall collisions
      if (b.pos.dx - b.radius < 0) {
        b.pos = Offset(b.radius, b.pos.dy);
        b.vel = Offset(-b.vel.dx, b.vel.dy);
      } else if (b.pos.dx + b.radius > _size.width) {
        b.pos = Offset(_size.width - b.radius, b.pos.dy);
        b.vel = Offset(-b.vel.dx, b.vel.dy);
      }
      if (b.pos.dy - b.radius < 0) {
        b.pos = Offset(b.pos.dx, b.radius);
        b.vel = Offset(b.vel.dx, -b.vel.dy);
      } else if (b.pos.dy + b.radius > _size.height) {
        b.pos = Offset(b.pos.dx, _size.height - b.radius);
        b.vel = Offset(b.vel.dx, -b.vel.dy);
      }
    }

    // Simple elastic collisions
    for (var i = 0; i < _bubbles.length; i++) {
      for (var j = i + 1; j < _bubbles.length; j++) {
        final a = _bubbles[i];
        final b = _bubbles[j];
        final dx = b.pos.dx - a.pos.dx;
        final dy = b.pos.dy - a.pos.dy;
        final dist = math.sqrt(dx * dx + dy * dy);
        final minDist = a.radius + b.radius;
        if (dist == 0 || dist >= minDist) continue;

        final nx = dx / dist;
        final ny = dy / dist;
        final rvx = b.vel.dx - a.vel.dx;
        final rvy = b.vel.dy - a.vel.dy;
        final velAlongNormal = rvx * nx + rvy * ny;

        if (velAlongNormal < 0) {
          final impulse = -velAlongNormal;
          a.vel = Offset(a.vel.dx - impulse * nx, a.vel.dy - impulse * ny);
          b.vel = Offset(b.vel.dx + impulse * nx, b.vel.dy + impulse * ny);
        }

        final overlap = minDist - dist;
        if (overlap > 0) {
          final correction = overlap / 2;
          a.pos = Offset(
            a.pos.dx - nx * correction,
            a.pos.dy - ny * correction,
          );
          b.pos = Offset(
            b.pos.dx + nx * correction,
            b.pos.dy + ny * correction,
          );
        }
      }
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _ensureSize(constraints.biggest);
          return CustomPaint(
            painter: _BubblePainter(bubbles: _bubbles, scheme: widget.scheme),
          );
        },
      ),
    );
  }
}

class _BubbleParticle {
  _BubbleParticle({
    required this.pos,
    required this.vel,
    required this.radius,
    required this.color,
  });

  Offset pos;
  Offset vel;
  final double radius;
  final Color color;
  bool initialized = false;
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({required this.bubbles, required this.scheme});

  final List<_BubbleParticle> bubbles;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bgPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          scheme.surface,
          scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          scheme.surface,
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    for (final bubble in bubbles) {
      final paint = Paint()..color = bubble.color;
      canvas.drawCircle(bubble.pos, bubble.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter oldDelegate) {
    return oldDelegate.bubbles != bubbles || oldDelegate.scheme != scheme;
  }
}

class _NeoIconBadge extends StatelessWidget {
  const _NeoIconBadge({
    required this.icon,
    required this.size,
    required this.color,
  });

  final IconData icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final highlight = (isDark ? Colors.white : Colors.white).withValues(
      alpha: isDark ? 0.08 : 0.65,
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surface,
        boxShadow: [
          BoxShadow(
            color: highlight,
            offset: const Offset(-6, -6),
            blurRadius: 14,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
            offset: const Offset(8, 10),
            blurRadius: 18,
          ),
        ],
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Icon(icon, color: color),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.errorContainer.withValues(alpha: 0.55),
        border: Border.all(color: scheme.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SupportBar extends StatelessWidget {
  const _SupportBar({required this.onCall, required this.onWhatsApp});

  final VoidCallback? onCall;
  final VoidCallback? onWhatsApp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AppSoftCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      radius: 18,
      child: Row(
        children: [
          Icon(Icons.support_agent_rounded, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.tr('auth_support_title'),
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: scheme.onSurface,
              ),
            ),
          ),
          _SupportIconButton(
            tooltip: context.tr('auth_support_call_tooltip'),
            icon: Icons.phone_rounded,
            onTap: onCall,
          ),
          const SizedBox(width: 10),
          _SupportIconButton(
            tooltip: context.tr('auth_support_whatsapp_tooltip'),
            icon: Icons.chat_rounded,
            onTap: onWhatsApp,
          ),
        ],
      ),
    );
  }
}

class _SupportIconButton extends StatelessWidget {
  const _SupportIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: Icon(icon, color: scheme.primary),
        ),
      ),
    );
  }
}

class _ClinicProfileStep {
  final String name;
  final String city;
  final String street;
  final String near;
  final String phone;
  final String? phone2;

  const _ClinicProfileStep({
    required this.name,
    required this.city,
    required this.street,
    required this.near,
    required this.phone,
    this.phone2,
  });
}
