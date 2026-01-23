import 'dart:io' show Platform;

import 'package:fluttertoast/fluttertoast.dart';

import 'app_error_reporter.dart';

class ToastUtils {
  ToastUtils._();

  static Future<void> show(
    String message, {
    ToastGravity gravity = ToastGravity.BOTTOM,
  }) async {
    if (message.trim().isEmpty) return;

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await Fluttertoast.showToast(
          msg: message,
          toastLength: Toast.LENGTH_LONG,
          gravity: gravity,
        );
        return;
      } catch (_) {
        // Fall back to snackbar below.
      }
    }

    AppErrorReporter.report(message);
  }
}
