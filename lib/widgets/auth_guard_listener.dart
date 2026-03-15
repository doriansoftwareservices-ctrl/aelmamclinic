import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/app_navigation.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/network_status_service.dart';
import 'package:aelmamclinic/utils/app_error_reporter.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

enum _PendingWipeGuardAction {
  wipe,
  signOut,
}

class AuthGuardListener extends StatefulWidget {
  final Widget child;
  final Duration interval;

  const AuthGuardListener({
    super.key,
    required this.child,
    this.interval = const Duration(seconds: 60),
  });

  @override
  State<AuthGuardListener> createState() => _AuthGuardListenerState();
}

class _AuthGuardListenerState extends State<AuthGuardListener>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _checking = false;
  bool _active = true;
  DateTime? _lastOfflineNoticeAt;
  bool _pendingWipePrompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runCheck();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _active = true;
      _startTimer();
      _runCheck();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _active = false;
      _timer?.cancel();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (!_active) return;
    _timer = Timer.periodic(widget.interval, (_) => _runCheck());
  }

  Future<void> _runCheck() async {
    if (!mounted || _checking || !_active) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) return;
    if (!auth.hasPendingLocalWipe) {
      _pendingWipePrompted = false;
    }
    _checking = true;
    try {
      if (auth.hasPendingLocalWipe && !_pendingWipePrompted) {
        _pendingWipePrompted = true;
        final resolved = await _showPendingWipeDialog(auth);
        _pendingWipePrompted = auth.hasPendingLocalWipe;
        if (!resolved || auth.hasPendingLocalWipe || !auth.isLoggedIn) {
          return;
        }
      }
      if (auth.isSuperAdmin && auth.hasNhostSession) return;
      final online = await NetworkStatusService.instance.refreshNow();
      if (!online) {
        _showOfflineNotice();
        return;
      }
      final result = await auth.reconcileAuthenticatedSession(
        reason: 'guard',
        bootstrapOnSuccess: true,
        bootstrapPull: false,
        resumeSyncOnSuccess: true,
      );
      if (!mounted || result.isSuccess) return;

      if (result.status == AuthSessionStatus.isolationRequired ||
          auth.hasPendingLocalWipe) {
        _pendingWipePrompted = true;
        await _showPendingWipeDialog(auth);
        _pendingWipePrompted = auth.hasPendingLocalWipe;
        return;
      }

      if (result.status == AuthSessionStatus.networkError ||
          result.status == AuthSessionStatus.unknown) {
        if (!NetworkStatusService.instance.isOnline || auth.isOffline) {
          _showOfflineNotice();
        } else {
          _showServerUnavailableNotice();
        }
        return;
      }

      if (result.status == AuthSessionStatus.noAccount && auth.isOffline) {
        _showOfflineNotice();
        return;
      }

      final message = _messageForStatus(result.status);
      if (message != null && mounted) {
        AppErrorReporter.info(message);
      }
      if (result.status == AuthSessionStatus.disabled ||
          result.status == AuthSessionStatus.accountFrozen) {
        await auth.signOut();
      }
    } finally {
      _checking = false;
    }
  }

  Future<bool> _showPendingWipeDialog(AuthProvider auth) async {
    if (!mounted) return false;
    final dialogContext =
        appNavigatorKey.currentState?.overlay?.context ??
            appNavigatorKey.currentContext;
    if (dialogContext == null) return false;
    final action = await showDialog<_PendingWipeGuardAction>(
      context: dialogContext,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Text(context.tr('auth_confirm_switch_title')),
          content: Text(
            context.tr('auth_pending_wipe_guard_message'),
            textAlign: TextAlign.start,
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_PendingWipeGuardAction.signOut),
              child: Text(context.tr('common_logout')),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_PendingWipeGuardAction.wipe),
              child: Text(context.tr('auth_action_backup_and_wipe_now')),
            ),
          ],
        );
      },
    );

    if (action == _PendingWipeGuardAction.signOut) {
      await auth.signOut();
      return true;
    }
    if (action != _PendingWipeGuardAction.wipe) return false;

    final ok = await auth.performPendingLocalWipe(
      createBackup: true,
      rebootstrap: true,
    );
    if (!mounted) return ok;
    AppErrorReporter.info(
      context.tr(
        ok ? 'auth_pending_wipe_success' : 'auth_pending_wipe_failed',
      ),
    );
    return ok;
  }

  void _showOfflineNotice() {
    final now = DateTime.now();
    if (_lastOfflineNoticeAt != null &&
        now.difference(_lastOfflineNoticeAt!).inSeconds < 20) {
      return;
    }
    _lastOfflineNoticeAt = now;
    if (!mounted) return;
    AppErrorReporter.report('يبدو ان الشبكة غير مستقرة لديك');
  }

  void _showServerUnavailableNotice() {
    final now = DateTime.now();
    if (_lastOfflineNoticeAt != null &&
        now.difference(_lastOfflineNoticeAt!).inSeconds < 20) {
      return;
    }
    _lastOfflineNoticeAt = now;
    if (!mounted) return;
    AppErrorReporter.report(
      context.trRaw('تعذر الوصول إلى الخادم حاليًا. حاول مرة أخرى بعد قليل.'),
    );
  }

  String? _messageForStatus(AuthSessionStatus status) {
    switch (status) {
      case AuthSessionStatus.disabled:
        return 'قم بمراجعة الإدارة.';
      case AuthSessionStatus.accountFrozen:
        return 'تم تجميد حساب العيادة. تواصل مع الإدارة.';
      case AuthSessionStatus.isolationRequired:
        return context.tr('auth_status_local_isolation_required');
      case AuthSessionStatus.planUpgradeRequired:
        return 'ناسف فالخطة الحالية للمرفق الصحي هي FREE يجب تجديد الاشتراك';
      case AuthSessionStatus.noAccount:
        return 'تعذّر التحقق من الحساب الحالي.';
      case AuthSessionStatus.signedOut:
      case AuthSessionStatus.networkError:
      case AuthSessionStatus.unknown:
      case AuthSessionStatus.success:
        return null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
