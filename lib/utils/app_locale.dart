import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

abstract final class AppLocale {
  static const String defaultLanguageCode = 'ar';
  static const String arabicLanguageCode = 'ar';
  static const String englishLanguageCode = 'en';

  static const Locale arabic = Locale(arabicLanguageCode);
  static const Locale english = Locale(englishLanguageCode);
  static const List<Locale> supportedLocales = <Locale>[arabic, english];

  static String normalize(String? languageCode) {
    switch ((languageCode ?? '').trim().toLowerCase()) {
      case englishLanguageCode:
        return englishLanguageCode;
      case arabicLanguageCode:
      default:
        return arabicLanguageCode;
    }
  }

  static Locale localeFromCode(String? languageCode) {
    return Locale(normalize(languageCode));
  }

  static bool isRtl(Locale locale) => isRtlCode(locale.languageCode);

  static bool isRtlCode(String? languageCode) {
    return normalize(languageCode) == arabicLanguageCode;
  }

  static TextDirection textDirectionForCode(String? languageCode) {
    return isRtlCode(languageCode) ? TextDirection.rtl : TextDirection.ltr;
  }

  static ui.TextDirection uiTextDirectionForCode(String? languageCode) {
    return isRtlCode(languageCode) ? ui.TextDirection.rtl : ui.TextDirection.ltr;
  }
}
