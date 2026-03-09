import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/providers/locale_provider.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class LanguageSwitchButton extends StatelessWidget {
  const LanguageSwitchButton({super.key});

  @override
  Widget build(BuildContext context) {
    final localeProvider = context.watch<LocaleProvider>();
    final current = localeProvider.languageCode;
    final next = localeProvider.nextLanguageCode.toUpperCase();
    final tooltip = current == 'ar'
        ? context.tr('language_switch_tooltip_to_en')
        : context.tr('language_switch_tooltip_to_ar');

    return Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: () => context.read<LocaleProvider>().toggleLanguage(),
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 13,
            letterSpacing: 0.8,
          ),
        ),
        child: Text(next),
      ),
    );
  }
}
