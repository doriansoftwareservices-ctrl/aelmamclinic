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
      _runCheck();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.interval, (_) => _runCheck());
  }

  Future<void> _runCheck() async {
    if (!mounted || _checking) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn || auth.isSuperAdmin) return;
    _checking = true;
    try {
      final result = await auth.refreshAndValidateCurrentUser();
      if (!mounted || result.isSuccess) return;

      await auth.signOut();
      final message = _messageForStatus(result.status);
      if (message != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      _checking = false;
    }
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
        return 'للأسف تم اقصائك من الإدارة للمرفق الصحي';
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
