import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
    _runCheck();
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
    _checking = true;
    try {
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

  void _showOfflineNotice() {
    final now = DateTime.now();
    if (_lastOfflineNoticeAt != null &&
        now.difference(_lastOfflineNoticeAt!).inSeconds < 20) {
      return;
    }
    _lastOfflineNoticeAt = now;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('التطبيق غير متصل بالانترنت')),
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
