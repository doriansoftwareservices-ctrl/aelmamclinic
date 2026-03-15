import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;

import 'package:aelmamclinic/utils/app_paths.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

/// Global error reporter that shows errors even in release builds.
class AppErrorReporter {
  AppErrorReporter._();

  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static void report(String message, {Object? error, StackTrace? stack}) {
    final state = messengerKey.currentState;
    if (state == null || message.trim().isEmpty) return;
    _logToFile('ERROR', message, error: error, stack: stack);
    void show() {
      state.showSnackBar(
        SnackBar(
          content: LocalizedText(message),
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

  static void info(String message, {Object? error, StackTrace? stack}) {
    final state = messengerKey.currentState;
    if (state == null || message.trim().isEmpty) return;
    _logToFile('INFO', message, error: error, stack: stack);
    void show() {
      state.showSnackBar(
        SnackBar(
          content: LocalizedText(message),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
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

  static Future<void> _logToFile(
    String level,
    String message, {
    Object? error,
    StackTrace? stack,
  }) async {
    try {
      final dir = await AppPaths.logsDir();
      final file = File(p.join(dir.path, 'app_errors.log'));
      final ts = DateTime.now().toIso8601String();
      final details = (error == null && stack == null)
          ? ''
          : '\nERROR: ${error ?? ''}\nSTACK: ${stack ?? ''}\n';
      await file.writeAsString(
        '[$ts][$level] $message$details\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // ignore logging failures
    }
  }

  static void logException(Object error, StackTrace stack) {
    _logToFile('EXCEPTION', 'Unhandled exception',
        error: error, stack: stack);
  }
}
