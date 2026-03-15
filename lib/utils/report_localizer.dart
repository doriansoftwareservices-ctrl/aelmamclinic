import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:aelmamclinic/l10n/raw_string_localizer.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:aelmamclinic/utils/app_locale.dart';
import 'package:aelmamclinic/utils/pdf_text.dart';

class ReportLocalizer {
  ReportLocalizer({String? languageCode})
      : languageCode = AppFormatters.resolvedLanguageCode(
          languageCode ?? Intl.getCurrentLocale(),
        );

  final String languageCode;

  bool get isRtl => AppLocale.isRtlCode(languageCode);

  String get htmlDir => isRtl ? 'rtl' : 'ltr';
  String get htmlLang => languageCode;

  pw.TextDirection get pdfTextDirection =>
      isRtl ? pw.TextDirection.rtl : pw.TextDirection.ltr;

  pw.TextAlign get startAlign =>
      isRtl ? pw.TextAlign.right : pw.TextAlign.left;

  pw.CrossAxisAlignment get crossAxisStart =>
      isRtl ? pw.CrossAxisAlignment.end : pw.CrossAxisAlignment.start;

  String tr(String raw) {
    final translated = RawStringLocalizer.translate(
      raw,
      languageCode: languageCode,
    );
    return AppFormatters.localizeDigits(
      translated,
      languageCode: languageCode,
    );
  }

  String pdf(String raw) => pdfText(tr(raw));

  String formatDate(
    DateTime date, {
    String pattern = 'yyyy-MM-dd',
  }) {
    return AppFormatters.formatDate(
      date,
      pattern: pattern,
      languageCode: languageCode,
    );
  }

  String formatDateTime(
    DateTime date, {
    String pattern = 'yyyy-MM-dd HH:mm',
  }) {
    return AppFormatters.formatDateTime(
      date,
      pattern: pattern,
      languageCode: languageCode,
    );
  }

  String formatNumber(
    num value, {
    int decimalDigits = 2,
  }) {
    final pattern = decimalDigits <= 0
        ? '#,##0'
        : '#,##0.${'0' * decimalDigits}';
    return AppFormatters.formatNumber(
      value,
      pattern: pattern,
      languageCode: languageCode,
    );
  }

  String clinicName(ClinicProfile clinic) {
    final primary = isRtl ? clinic.nameAr.trim() : clinic.nameEn.trim();
    final fallback = isRtl ? clinic.nameEn.trim() : clinic.nameAr.trim();
    return primary.isNotEmpty ? primary : fallback;
  }

  String clinicAddress(ClinicProfile clinic) {
    final primary = isRtl ? clinic.addressAr.trim() : clinic.addressEn.trim();
    final fallback = isRtl ? clinic.addressEn.trim() : clinic.addressAr.trim();
    return primary.isNotEmpty ? primary : fallback;
  }

  String clinicPhones(ClinicProfile clinic) => clinic.phonesDisplay;

  String withLabel(String label, String value) => '${tr(label)}: $value';

  String fileStem(String raw) {
    final localized = tr(raw);
    final sanitized = localized
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ')
        .replaceAll(RegExp(r'[^A-Za-z0-9\u0600-\u06FF._ -]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isNotEmpty) return sanitized;
    return isRtl ? 'ملف' : 'file';
  }

  String fileName(
    String rawStem, {
    required String extension,
    Iterable<Object?> suffixes = const <Object?>[],
  }) {
    final stem = fileStem(rawStem);
    final resolvedSuffixes = suffixes
        .where((value) => value != null && value.toString().trim().isNotEmpty)
        .map((value) => fileStem(value.toString()))
        .where((value) => value.isNotEmpty)
        .toList();
    final base = <String>[stem, ...resolvedSuffixes].join('_');
    final normalizedExtension = extension.replaceFirst('.', '').trim();
    if (normalizedExtension.isEmpty) return base;
    return '$base.$normalizedExtension';
  }

  String pageLabel(int pageNumber, int pagesCount) {
    final counter = AppFormatters.localizeDigits(
      '$pageNumber/$pagesCount',
      languageCode: languageCode,
    );
    final prefix = isRtl ? 'الصفحة' : 'Page';
    return '$prefix $counter';
  }

  pw.PageTheme pageTheme({
    required pw.Font base,
    required pw.Font bold,
    PdfPageFormat pageFormat = PdfPageFormat.a4,
    pw.EdgeInsets margin = const pw.EdgeInsets.all(20),
  }) {
    return pw.PageTheme(
      pageFormat: pageFormat,
      margin: margin,
      textDirection: pdfTextDirection,
      theme: pw.ThemeData.withFont(base: base, bold: bold),
    );
  }

  pw.Widget buildLetterhead({
    required ClinicProfile clinic,
    required pw.Font regular,
    required pw.Font bold,
    Uint8List? logoData,
  }) {
    final details = pw.Expanded(
      child: pw.Column(
        crossAxisAlignment: crossAxisStart,
        children: [
          pw.Text(
            pdf(clinicName(clinic)),
            textAlign: startAlign,
            style: pw.TextStyle(
              font: bold,
              fontSize: 14,
              color: PdfColors.blueGrey,
            ),
          ),
          pw.Text(
            pdf(clinicAddress(clinic)),
            textAlign: startAlign,
            style: pw.TextStyle(font: regular, fontSize: 9),
          ),
          pw.Text(
            pdf(withLabel('الهاتف', clinicPhones(clinic))),
            textAlign: startAlign,
            style: pw.TextStyle(font: regular, fontSize: 9),
          ),
        ],
      ),
    );

    final logo = pw.Container(
      width: 100,
      height: 60,
      alignment: pw.Alignment.topCenter,
      child: logoData == null
          ? pw.SizedBox()
          : pw.Image(pw.MemoryImage(logoData), width: 56, height: 56),
    );

    final children = isRtl
        ? <pw.Widget>[details, logo]
        : <pw.Widget>[logo, pw.SizedBox(width: 12), details];

    return pw.Column(
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: children,
        ),
        pw.SizedBox(height: 8),
        pw.Container(height: 1, color: PdfColors.grey500),
      ],
    );
  }

  pw.Widget buildFooter({
    required ClinicProfile clinic,
    required pw.Font regular,
    required int pageNumber,
    required int pagesCount,
  }) {
    final parts = <String>[
      clinicName(clinic),
      clinicAddress(clinic),
      withLabel('الهاتف', clinicPhones(clinic)),
    ].where((part) => part.trim().isNotEmpty).toList();

    return pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(width: 0.6, color: PdfColors.grey300),
        ),
      ),
      child: pw.Row(
        children: [
          pw.Expanded(
            child: pw.Text(
              pdf(parts.join(' - ')),
              textAlign: startAlign,
              style: pw.TextStyle(
                font: regular,
                fontSize: 9,
                color: PdfColors.blueGrey,
              ),
            ),
          ),
          pw.SizedBox(width: 8),
          pw.Text(
            pdf(pageLabel(pageNumber, pagesCount)),
            style: pw.TextStyle(
              font: regular,
              fontSize: 9,
              color: PdfColors.blueGrey,
            ),
          ),
        ],
      ),
    );
  }
}
