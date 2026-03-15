import 'dart:io' show Platform;

import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';

import 'app_error_reporter.dart';
import 'app_formatters.dart';
import 'package:aelmamclinic/l10n/raw_string_localizer.dart';

class ToastUtils {
  ToastUtils._();

  static Future<void> show(
    String message, {
    ToastGravity gravity = ToastGravity.BOTTOM,
  }) async {
    if (message.trim().isEmpty) return;
    final languageCode = AppFormatters.resolvedLanguageCode(
      Intl.defaultLocale,
    );
    final localizedMessage = AppFormatters.localizeDigits(
      RawStringLocalizer.translate(
        message,
        languageCode: languageCode,
      ),
      languageCode: languageCode,
    );

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await Fluttertoast.showToast(
          msg: localizedMessage,
          toastLength: Toast.LENGTH_LONG,
          gravity: gravity,
        );
        return;
      } catch (_) {
        // Fall back to snackbar below.
      }
    }

    AppErrorReporter.report(localizedMessage);
  }
}
