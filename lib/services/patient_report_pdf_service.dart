import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_report.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/utils/pdf_fonts.dart';
import 'package:aelmamclinic/utils/pdf_text.dart';
import 'package:aelmamclinic/utils/report_localizer.dart';

const PdfColor kReportAccent = PdfColor.fromInt(0xFF004A61);

class PatientReportPdfService {
  static Future<Uint8List> buildPdf({
    required Patient patient,
    required PatientReport report,
  }) async {
    final i18n = ReportLocalizer();
    final fonts = await loadPdfFonts();
    final cairo = fonts.regular;
    final cairoBold = fonts.bold;

    Uint8List? logoData;
    try {
      logoData = await ClinicProfileService.loadReportLogoBytes();
    } catch (_) {
      logoData = null;
    }
    final clinic = await ClinicProfileService.loadActiveOrFallback();

    final snapshot = report.snapshot;
    final complaint = (snapshot['complaint'] as Map?) ?? const {};
    final complaintTitle = (complaint['title'] ?? '').toString().trim();

    final doc = pw.Document();
    final baseText = pw.TextStyle(font: cairo, fontSize: 12, height: 1.35);
    final boldText = pw.TextStyle(font: cairoBold, fontSize: 12, height: 1.35);
    final pageTheme = i18n.pageTheme(base: cairo, bold: cairoBold);

    pw.Widget thinDivider([double v = 6]) => pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: v),
          child: pw.Container(height: 0.7, color: PdfColors.grey300),
        );

    pw.Widget infoRow(String label, String value) {
      final labelWidget = pw.Text(
        i18n.pdf(label),
        style: boldText,
        textAlign: i18n.startAlign,
      );
      final valueWidget = pw.Expanded(
        child: pw.Text(
          pdfText(value),
          style: baseText,
          textAlign: i18n.startAlign,
        ),
      );
      return pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: i18n.isRtl
            ? <pw.Widget>[valueWidget, pw.SizedBox(width: 14), labelWidget]
            : <pw.Widget>[labelWidget, pw.SizedBox(width: 14), valueWidget],
      );
    }

    doc.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        header: (_) => i18n.buildLetterhead(
          clinic: clinic,
          regular: cairo,
          bold: cairoBold,
          logoData: logoData,
        ),
        footer: (ctx) => i18n.buildFooter(
          clinic: clinic,
          regular: cairo,
          pageNumber: ctx.pageNumber,
          pagesCount: ctx.pagesCount,
        ),
        build: (_) => [
          pw.SizedBox(height: 10),
          _buildTitleRow(cairoBold, report, i18n),
          pw.SizedBox(height: 10),
          infoRow('اسم المريض', patient.name),
          thinDivider(),
          infoRow('العمر', i18n.formatNumber(patient.age, decimalDigits: 0)),
          if (complaintTitle.isNotEmpty) ...[
            thinDivider(),
            infoRow('الشكوى', complaintTitle),
          ],
          pw.SizedBox(height: 14),
          _buildReportText(cairo, report.reportText, i18n),
          pw.SizedBox(height: 18),
          _buildSignatureFooter(cairo, i18n),
        ],
      ),
    );

    return doc.save();
  }

  static Future<void> sharePdf({
    required Patient patient,
    required PatientReport report,
  }) async {
    final bytes = await buildPdf(patient: patient, report: report);
    final stamp = DateFormat('yyyyMMdd').format(DateTime.now());
    final i18n = ReportLocalizer();
    await Printing.sharePdf(
      bytes: bytes,
      filename: i18n.fileName(
        'تقارير المريض',
        extension: 'pdf',
        suffixes: <Object?>[patient.id, stamp],
      ),
    );
  }

  static pw.Widget _buildTitleRow(
    pw.Font bold,
    PatientReport report,
    ReportLocalizer i18n,
  ) {
    final date = report.createdAt != null
        ? i18n.formatDateTime(
            report.createdAt!,
            pattern: 'yyyy-MM-dd • HH:mm',
          )
        : i18n.formatDate(DateTime.now());
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(i18n.pdf(i18n.withLabel('التاريخ', date)),
            style: pw.TextStyle(font: bold, fontSize: 11)),
        pw.Text('',
            style: pw.TextStyle(font: bold, fontSize: 16, color: kReportAccent)),
      ],
    );
  }

  static pw.Widget _buildReportText(
    pw.Font base,
    String reportText,
    ReportLocalizer i18n,
  ) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Text(
        reportText.isEmpty ? '—' : pdfText(reportText),
        style: pw.TextStyle(font: base, fontSize: 11, height: 1.4),
        textAlign: i18n.startAlign,
      ),
    );
  }

  static pw.Widget _buildSignatureFooter(
    pw.Font base,
    ReportLocalizer i18n,
  ) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(i18n.pdf("${i18n.tr('الطبيب')}: ____________________"),
            style: pw.TextStyle(font: base, fontSize: 10)),
        pw.Text(i18n.pdf("${i18n.tr('التوقيع')}: ____________________"),
            style: pw.TextStyle(font: base, fontSize: 10)),
      ],
    );
  }
}
