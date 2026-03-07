import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/network_status_service.dart';

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
    if (!auth.isLoggedIn || auth.isSuperAdmin) return;
    if (!NetworkStatusService.instance.isOnline) {
      _showOfflineNotice();
      return;
    }
    _checking = true;
    try {
      if (!auth.hasNhostSession) {
        await auth.ensureNhostSessionReady(reason: 'guard');
        if (!auth.hasNhostSession) return;
      }
      if (auth.hasPendingLocalWipe && !_pendingWipePrompted) {
        _pendingWipePrompted = true;
        await _showPendingWipeDialog(auth);
      }
      final result = await auth.refreshAndValidateCurrentUser();
      if (!mounted || result.isSuccess) return;

      if (result.status == AuthSessionStatus.networkError ||
          result.status == AuthSessionStatus.unknown) {
        _showOfflineNotice();
        return;
      }

      if (result.status == AuthSessionStatus.noAccount && auth.isOffline) {
        _showOfflineNotice();
        return;
      }

      final message = _messageForStatus(result.status);
      if (message != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
      if (result.status == AuthSessionStatus.disabled ||
          result.status == AuthSessionStatus.accountFrozen ||
          result.status == AuthSessionStatus.planUpgradeRequired ||
          result.status == AuthSessionStatus.signedOut) {
        await auth.signOut();
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _showPendingWipeDialog(AuthProvider auth) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('تغيير الحساب'),
          content: const Text(
            'تم رصد تبديل الحساب أو اختلاف البيانات المحلية. يُنصح بمسح البيانات المحلية '
            'لتجنب اختلاط البيانات بين العيادات. سيتم إنشاء نسخة احتياطية قبل المسح.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('لاحقًا'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('مسح الآن (موصى به)'),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      final ok = await auth.performPendingLocalWipe(
        createBackup: true,
        rebootstrap: true,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? 'تم إنشاء نسخة احتياطية ومسح البيانات المحلية.'
              : 'فشل تنفيذ المسح. يرجى المحاولة مرة أخرى.'),
        ),
      );
    }
  }

  void _showOfflineNotice() {
    final now = DateTime.now();
    if (_lastOfflineNoticeAt != null &&
        now.difference(_lastOfflineNoticeAt!).inSeconds < 20) {
      return;
    }
    _lastOfflineNoticeAt = now;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('يبدو ان الشبكة غير مستقرة لديك')),
    );
  }

  String? _messageForStatus(AuthSessionStatus status) {
    switch (status) {
      case AuthSessionStatus.disabled:
        return 'قم بمراجعة الإدارة.';
      case AuthSessionStatus.accountFrozen:
        return 'تم تجميد حساب العيادة. تواصل مع الإدارة.';
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
