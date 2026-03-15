import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/utils/app_locale.dart';

abstract final class AppFormatters {
  static String resolvedLanguageCode([String? languageCode]) {
    final raw = languageCode ?? Intl.getCurrentLocale();
    return AppLocale.normalize(raw);
  }

  static Locale localeOf(BuildContext context) {
    return AppLocale.localeFromCode(Localizations.localeOf(context).languageCode);
  }

  static DateFormat dateFormat(
    String pattern, {
    String? languageCode,
  }) {
    return DateFormat(pattern, resolvedLanguageCode(languageCode));
  }

  static NumberFormat numberFormat(
    String pattern, {
    String? languageCode,
  }) {
    return NumberFormat(pattern, resolvedLanguageCode(languageCode));
  }

  static NumberFormat currency({
    String symbol = '',
    int decimalDigits = 2,
    String? languageCode,
  }) {
    return NumberFormat.currency(
      locale: resolvedLanguageCode(languageCode),
      symbol: symbol,
      decimalDigits: decimalDigits,
    );
  }

  static String localizeDigits(
    String raw, {
    String? languageCode,
  }) {
    if (raw.isEmpty) return raw;
    const english = <String>['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    const arabicIndic = <String>[
      '٠',
      '١',
      '٢',
      '٣',
      '٤',
      '٥',
      '٦',
      '٧',
      '٨',
      '٩',
    ];
    const easternArabicIndic = <String>[
      '۰',
      '۱',
      '۲',
      '۳',
      '۴',
      '۵',
      '۶',
      '۷',
      '۸',
      '۹',
    ];

    var output = raw;
    for (var i = 0; i < english.length; i++) {
      output = output
          .replaceAll(arabicIndic[i], english[i])
          .replaceAll(easternArabicIndic[i], english[i]);
    }

    return output
        .replaceAll('٫', '.')
        .replaceAll('٬', ',')
        .replaceAll('٪', '%')
        .replaceAll('−', '-');
  }

  static String formatDate(
    DateTime date, {
    String pattern = 'yyyy-MM-dd',
    String? languageCode,
  }) {
    final formatted =
        dateFormat(pattern, languageCode: languageCode).format(date.toLocal());
    return localizeDigits(formatted, languageCode: languageCode);
  }

  static String formatDateTime(
    DateTime date, {
    String pattern = 'yyyy-MM-dd HH:mm',
    String? languageCode,
  }) {
    final formatted =
        dateFormat(pattern, languageCode: languageCode).format(date.toLocal());
    return localizeDigits(formatted, languageCode: languageCode);
  }

  static String formatNumber(
    num value, {
    String pattern = '#,##0.00',
    String? languageCode,
  }) {
    final formatted =
        numberFormat(pattern, languageCode: languageCode).format(value);
    return localizeDigits(formatted, languageCode: languageCode);
  }

  static String formatCurrency(
    num value, {
    String symbol = '',
    int decimalDigits = 2,
    String? languageCode,
  }) {
    final formatted = currency(
      symbol: symbol,
      decimalDigits: decimalDigits,
      languageCode: languageCode,
    ).format(value);
    return localizeDigits(formatted, languageCode: languageCode);
  }

  static String localizeDateKey(
    String raw, {
    String? languageCode,
  }) {
    final value = raw.trim();
    if (value.isEmpty) return value;

    DateTime? parsed;
    String? pattern;
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      parsed = DateTime.tryParse(value);
      pattern = 'yyyy-MM-dd';
    } else if (RegExp(r'^\d{4}-\d{2}$').hasMatch(value)) {
      parsed = DateTime.tryParse('$value-01');
      pattern = 'yyyy-MM';
    } else if (RegExp(r'^\d{2}$').hasMatch(value)) {
      return localizeDigits(value, languageCode: languageCode);
    } else if (RegExp(r'^\d{4}/\d{2}/\d{2}$').hasMatch(value)) {
      parsed = DateTime.tryParse(value.replaceAll('/', '-'));
      pattern = 'yyyy/MM/dd';
    }

    if (parsed == null || pattern == null) {
      return localizeDigits(value, languageCode: languageCode);
    }

    return formatDate(parsed, pattern: pattern, languageCode: languageCode);
  }
}
