import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aelmamclinic/services/notification_service.dart';
import 'package:aelmamclinic/services/push_notifications_service.dart';
import 'package:aelmamclinic/utils/app_locale.dart';
import 'package:aelmamclinic/utils/notifications_helper.dart';

class LocaleProvider extends ChangeNotifier {
  LocaleProvider() {
    Intl.defaultLocale = _languageCode;
    ready = _load();
  }

  static const String prefsKey = 'app.locale_code';

  String _languageCode = AppLocale.defaultLanguageCode;
  late final Future<void> ready;

  String get languageCode => _languageCode;
  Locale get locale => AppLocale.localeFromCode(_languageCode);
  bool get isArabic => _languageCode == AppLocale.arabicLanguageCode;
  String get nextLanguageCode =>
      isArabic ? AppLocale.englishLanguageCode : AppLocale.arabicLanguageCode;

  Future<void> toggleLanguage() => setLanguageCode(nextLanguageCode);

  Future<void> _syncLanguageSideEffects(String languageCode) async {
    try {
      await NotificationService().updateLanguageCode(languageCode);
      await NotificationsHelper.instance.setLanguageCode(languageCode);
      await PushNotificationsService.instance.syncLocale(
        languageCode: languageCode,
      );
    } catch (error, stackTrace) {
      debugPrint(
        'Locale side effects sync failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> setLanguageCode(String languageCode) async {
    final normalized = AppLocale.normalize(languageCode);
    if (_languageCode == normalized) {
      Intl.defaultLocale = _languageCode;
      unawaited(_syncLanguageSideEffects(_languageCode));
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    _languageCode = normalized;
    Intl.defaultLocale = _languageCode;
    await prefs.setString(prefsKey, _languageCode);
    notifyListeners();
    unawaited(_syncLanguageSideEffects(_languageCode));
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(prefsKey);
    final normalized = AppLocale.normalize(stored);
    Intl.defaultLocale = normalized;
    _languageCode = normalized;
    await _syncLanguageSideEffects(_languageCode);
    notifyListeners();
  }
}
