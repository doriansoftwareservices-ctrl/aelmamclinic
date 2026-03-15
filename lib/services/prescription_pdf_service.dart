// lib/services/prescription_pdf_service.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'package:aelmamclinic/models/drug.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/utils/pdf_fonts.dart';
import 'package:aelmamclinic/utils/pdf_text.dart';
import 'package:aelmamclinic/utils/report_localizer.dart';

/*── ألوان موحَّدة ──*/
const PdfColor kAccent = PdfColor.fromInt(0xFF004A61);
const PdfColor kLightAccent = PdfColor.fromInt(0xFF9ED9E6);

class PrescriptionPdfService {
/*──────────────────────── بناء ملف وصفة منفردة ───────────────────────*/
  static Future<Uint8List> buildPdf({
    required Patient patient,
    required List<Map<String, dynamic>> items, // [{drug,days,times}, …]
    Doctor? doctor,
    required DateTime recordDate,
  }) async {
    final i18n = ReportLocalizer();
    // الخط
    final fonts = await loadPdfFonts();
    final cairo = fonts.regular;
    final cairoBold = fonts.bold;

    // الشعار
    final logoData = await ClinicProfileService.loadReportLogoBytes();

    final clinic = await ClinicProfileService.loadActiveOrFallback();

    // رأس الجدول
    final tableHeaders = <String>[
      i18n.tr('الدواء'),
      i18n.tr('أيام'),
      i18n.tr('مرّات/يوم'),
    ];

    final doc = pw.Document();
    final pageTheme = i18n.pageTheme(base: cairo, bold: cairoBold);

    pw.Widget thinDivider([double v = 6]) => pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: v),
          child: pw.Container(height: 0.7, color: PdfColors.grey300),
        );

    pw.Widget sectionTitle(String title) => pw.Row(
          children: [
            pw.Expanded(child: pw.Container(height: 0.8, color: PdfColors.grey300)),
            pw.Container(
              margin: const pw.EdgeInsets.symmetric(horizontal: 8),
              padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey400, width: 0.8),
                borderRadius: pw.BorderRadius.circular(4),
              ),
              child: pw.Text(
                i18n.pdf(title),
                style: pw.TextStyle(
                    font: cairoBold, fontSize: 15, letterSpacing: 1.1),
              ),
            ),
            pw.Expanded(child: pw.Container(height: 0.8, color: PdfColors.grey300)),
          ],
        );

    pw.Widget infoRow(String label, String value) {
      final labelWidget = pw.Text(
        i18n.pdf(label),
        style: pw.TextStyle(font: cairoBold, fontSize: 12, height: 1.35),
        textAlign: i18n.startAlign,
      );
      final valueWidget = pw.Expanded(
        child: pw.Text(
          pdfText(value),
          style: pw.TextStyle(font: cairo, fontSize: 12, height: 1.35),
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
        header: (_) => pw.Column(
          children: [
            i18n.buildLetterhead(
              clinic: clinic,
              regular: cairo,
              bold: cairoBold,
              logoData: logoData,
            ),
          ],
        ),
        footer: (ctx) => i18n.buildFooter(
          clinic: clinic,
          regular: cairo,
          pageNumber: ctx.pageNumber,
          pagesCount: ctx.pagesCount,
        ),
        build: (_) => [
          pw.SizedBox(height: 10),
          sectionTitle(i18n.isRtl ? 'الوصفة الطبية' : 'PRESCRIPTION'),
          pw.SizedBox(height: 10),
          infoRow('اسم المريض', patient.name),
          thinDivider(),
          infoRow('العمر', i18n.formatNumber(patient.age, decimalDigits: 0)),
          thinDivider(),
          if (patient.phoneNumber.isNotEmpty)
            infoRow('رقم الهاتف', patient.phoneNumber)
          else
            infoRow('رقم الهاتف', '—'),
          if (doctor != null) ...[
            thinDivider(),
            infoRow('اسم الطبيب', doctor.name),
          ],
          thinDivider(),
          infoRow('التاريخ', i18n.formatDate(recordDate)),
          pw.SizedBox(height: 18),
          pw.Row(
            children: [
              pw.Expanded(
                  child: pw.Container(height: 0.6, color: PdfColors.grey300)),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8),
                child: pw.Text(i18n.pdf('الأدوية'),
                    style: pw.TextStyle(font: cairoBold, fontSize: 14)),
              ),
              pw.Expanded(
                  child: pw.Container(height: 0.6, color: PdfColors.grey300)),
            ],
          ),
          pw.SizedBox(height: 6),
          _buildTable(cairo, cairoBold, tableHeaders, items, i18n),
        ],
      ),
    );

    return doc.save();
  }

/*──────────────────────── تصدير قائمة كاملة ────────────────────────*/
  /// يقبل مصفوفة من السجلات تحتوي على:
  /// id, patientName, phone, doctorName, recordDate
  static Future<Uint8List> exportList(List<dynamic> records) async {
    final i18n = ReportLocalizer();
    final fonts = await loadPdfFonts();
    final cairo = fonts.regular;
    final cairoBold = fonts.bold;

    final headers = [
      '#',
      i18n.tr('المريض'),
      i18n.tr('رقم الهاتف'),
      i18n.tr('الطبيب'),
      i18n.tr('التاريخ'),
    ];

    final data = <List<String>>[];
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      data.add([
        i18n.formatNumber(i + 1, decimalDigits: 0),
        pdfText('${r.patientName}'),
        '${r.phone}',
        pdfText(r.doctorName ?? '—'),
        i18n.formatDate(r.recordDate as DateTime),
      ]);
    }

    final clinic = await ClinicProfileService.loadActiveOrFallback();
    Uint8List? logoData;
    try {
      logoData = await ClinicProfileService.loadReportLogoBytes();
    } catch (_) {
      logoData = null;
    }

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: i18n.pageTheme(
          base: cairo,
          bold: cairoBold,
          pageFormat: PdfPageFormat.a4.landscape,
        ),
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
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text(
                i18n.pdf('قائمة الوصفات الطبية'),
                textAlign: i18n.startAlign,
                style: pw.TextStyle(
                  font: cairo,
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                  color: kAccent,
                ),
              ),
              pw.SizedBox(height: 20),
              pw.TableHelper.fromTextArray(
                headers: headers.map(pdfText).toList(),
                data: data,
                headerStyle: pw.TextStyle(
                  font: cairo,
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
                cellStyle: pw.TextStyle(font: cairo, fontSize: 10),
                headerDecoration: pw.BoxDecoration(color: kLightAccent),
                cellAlignment: pw.Alignment.center,
                columnWidths: {
                  0: const pw.FlexColumnWidth(1),
                  1: const pw.FlexColumnWidth(3),
                  2: const pw.FlexColumnWidth(2),
                  3: const pw.FlexColumnWidth(3),
                  4: const pw.FlexColumnWidth(2),
                },
              ),
            ],
          ),
        ],
      ),
    );
    return doc.save();
  }

/*──────────────────────── حفظ ملف مؤقت ────────────────────────*/
  static Future<File> saveTempFile(
    Uint8List bytes,
    Directory dir, {
    String? fileName,
  }) async {
    final name = fileName ??
        'prescriptions_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final path = p.join(dir.path, name);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

/*──────────────────────── مشاركة/طباعة وصفة ─────────────────────*/
  static Future<void> sharePdf({
    required Patient patient,
    required List<Map<String, dynamic>> items,
    Doctor? doctor,
    required DateTime recordDate,
  }) async {
    final bytes = await buildPdf(
      patient: patient,
      items: items,
      doctor: doctor,
      recordDate: recordDate,
    );
    final i18n = ReportLocalizer();

    await Printing.sharePdf(
      bytes: bytes,
      filename: i18n.fileName(
        'الوصفة الطبية',
        extension: 'pdf',
        suffixes: <Object?>[
          patient.id,
          DateFormat('yyyyMMdd').format(recordDate),
        ],
      ),
    );
  }
  static pw.Widget _buildTable(
    pw.Font cairo,
    pw.Font cairoBold,
    List<String> headers,
    List<Map<String, dynamic>> items,
    ReportLocalizer i18n,
  ) {
    final data = <List<String>>[];
    for (final it in items) {
      final drug = it['drug'] as Drug;
      final days = it['days'] as int;
      final times = it['times'] as int;
      data.add([
        pdfText(drug.name),
        i18n.formatNumber(days, decimalDigits: 0),
        i18n.formatNumber(times, decimalDigits: 0),
      ]);
    }

    return pw.TableHelper.fromTextArray(
      headers: headers.map(pdfText).toList(),
      data: data,
      headerStyle: pw.TextStyle(
          font: cairoBold, fontWeight: pw.FontWeight.bold, fontSize: 11),
      cellStyle: pw.TextStyle(font: cairo, fontSize: 10),
      headerDecoration: pw.BoxDecoration(color: kLightAccent),
      cellAlignment: pw.Alignment.center,
      columnWidths: {
        0: const pw.FlexColumnWidth(4),
        1: const pw.FlexColumnWidth(1),
        2: const pw.FlexColumnWidth(1),
      },
    );
  }
}
