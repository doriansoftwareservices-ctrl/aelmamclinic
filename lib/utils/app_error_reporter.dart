import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Global error reporter that shows errors even in release builds.
class AppErrorReporter {
  AppErrorReporter._();

  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static void report(String message) {
    final state = messengerKey.currentState;
    if (state == null || message.trim().isEmpty) return;
    void show() {
      state.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    }
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      show();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => show());
    }
  }
}
