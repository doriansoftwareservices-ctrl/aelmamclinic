import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aelmamclinic/providers/activation_provider.dart';

class ActivationListener extends StatefulWidget {
  final Widget child;

  const ActivationListener({super.key, required this.child});

  @override
  State<ActivationListener> createState() => _ActivationListenerState();
}

class _ActivationListenerState extends State<ActivationListener>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialCheck();
  }

  Future<void> _initialCheck() async {
    // تأخير بسيط لضمان اكتمال بناء الشجرة
    await Future.delayed(const Duration(milliseconds: 300));
    await _checkActivation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkActivation();
    }
  }

  Future<void> _checkActivation() async {
    final activation = Provider.of<ActivationProvider>(context, listen: false);

    // التحقق من التلاعب بالوقت أو انتهاء الصلاحية
    if (await _isTimeTampered() ||
        (activation.expiryDate != null &&
            DateTime.now().isAfter(activation.expiryDate!))) {
      await activation.deactivate();
    }
  }

  Future<bool> _isTimeTampered() async {
    final prefs = await SharedPreferences.getInstance();
    final lastCheck = prefs.getString('lastTimeCheck');
    if (lastCheck != null) {
      final lastCheckTime = DateTime.parse(lastCheck);
      final now = DateTime.now();
      final diff = now.difference(lastCheckTime);

      // إذا تم الرجوع بالوقت (diff سالب) أو التقدم بأكثر من يوم
      if (diff.isNegative || diff.inDays > 1) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ActivationProvider>(
      builder: (context, activation, _) {
        if (!activation.isActivated) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(context).pushReplacementNamed('/activation');
          });
        }
        return widget.child;
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
