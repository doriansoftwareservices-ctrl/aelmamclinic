import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:aelmamclinic/utils/app_locale.dart';

class AppLocalizations {
  AppLocalizations._({
    required this.locale,
    required Map<String, String> strings,
  }) : _strings = strings;

  final Locale locale;
  final Map<String, String> _strings;

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static final Map<String, Future<Map<String, String>>> _cache =
      <String, Future<Map<String, String>>>{};

  static AppLocalizations of(BuildContext context) {
    final localizations = maybeOf(context);
    assert(localizations != null, 'AppLocalizations is not available in context.');
    return localizations!;
  }

  static AppLocalizations? maybeOf(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static Future<AppLocalizations> load(Locale locale) async {
    final code = AppLocale.normalize(locale.languageCode);
    final fallback = await _loadStrings(AppLocale.defaultLanguageCode);
    final selected = code == AppLocale.defaultLanguageCode
        ? fallback
        : await _loadStrings(code);
    return AppLocalizations._(
      locale: AppLocale.localeFromCode(code),
      strings: <String, String>{...fallback, ...selected},
    );
  }

  String tr(
    String key, {
    Map<String, Object?> params = const <String, Object?>{},
  }) {
    var value = _strings[key] ?? key;
    if (params.isEmpty) {
      return value;
    }
    params.forEach((name, replacement) {
      value = value.replaceAll('{$name}', '${replacement ?? ''}');
    });
    return value;
  }

  static Future<Map<String, String>> _loadStrings(String languageCode) {
    final normalized = AppLocale.normalize(languageCode);
    return _cache.putIfAbsent(normalized, () async {
      final raw = await rootBundle.loadString('assets/l10n/app_$normalized.arb');
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map<String, String>((key, value) {
        if (key.startsWith('@')) {
          return MapEntry<String, String>(key, '');
        }
        return MapEntry<String, String>(key, value?.toString() ?? '');
      })
        ..removeWhere((key, _) => key.startsWith('@'));
    });
  }
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocale.supportedLocales
        .any((supported) => supported.languageCode == locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) {
    return AppLocalizations.load(locale);
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) {
    return false;
  }
}
