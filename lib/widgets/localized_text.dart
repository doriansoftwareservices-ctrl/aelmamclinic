import 'package:flutter/material.dart';

import 'package:aelmamclinic/l10n/raw_string_localizer.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';

class LocalizedText extends StatelessWidget {
  const LocalizedText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) {
    final resolvedLocale = locale ?? Localizations.localeOf(context);
    final translated = RawStringLocalizer.translate(
      data,
      languageCode: resolvedLocale.languageCode,
    );
    final displayText = AppFormatters.localizeDigits(
      translated,
      languageCode: resolvedLocale.languageCode,
    );
    final translatedSemantics = semanticsLabel == null
        ? null
        : AppFormatters.localizeDigits(
            RawStringLocalizer.translate(
              semanticsLabel!,
              languageCode: resolvedLocale.languageCode,
            ),
            languageCode: resolvedLocale.languageCode,
          );

    return Text(
      displayText,
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: resolvedLocale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: translatedSemantics,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}
