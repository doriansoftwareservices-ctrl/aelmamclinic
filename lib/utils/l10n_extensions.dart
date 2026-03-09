import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'package:aelmamclinic/l10n/app_localizations.dart';
import 'package:aelmamclinic/l10n/raw_string_localizer.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:aelmamclinic/utils/app_locale.dart';

extension AppL10nBuildContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  String tr(
    String key, {
    Map<String, Object?> params = const <String, Object?>{},
  }) {
    return l10n.tr(key, params: params);
  }

  String trRaw(String raw) {
    final translated =
        RawStringLocalizer.translate(raw, languageCode: currentLocaleCode);
    return AppFormatters.localizeDigits(
      translated,
      languageCode: currentLocaleCode,
    );
  }

  Locale get appLocale => Localizations.localeOf(this);
  String get currentLocaleCode => AppLocale.normalize(appLocale.languageCode);
  bool get isRtl => AppLocale.isRtl(appLocale);
  TextDirection get appTextDirection =>
      AppLocale.textDirectionForCode(currentLocaleCode);
  ui.TextDirection get appUiTextDirection =>
      AppLocale.uiTextDirectionForCode(currentLocaleCode);
}
