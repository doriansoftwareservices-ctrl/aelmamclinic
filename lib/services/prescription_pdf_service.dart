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
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/utils/pdf_fonts.dart';
import 'package:aelmamclinic/utils/pdf_text.dart';

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
    // الخط
    final fonts = await loadPdfFonts();
    final cairo = fonts.regular;
    final cairoBold = fonts.bold;

    // الشعار
    final logoData = await ClinicProfileService.loadReportLogoBytes();

    final clinic = await ClinicProfileService.loadActiveOrFallback();

    // رأس الجدول
    const tableHeaders = ['الدواء', 'أيام', 'مرّات/يوم'];

    final doc = pw.Document();
    final pageTheme = pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(20),
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: cairo, bold: cairoBold),
    );

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
                title,
                style: pw.TextStyle(
                    font: cairoBold, fontSize: 15, letterSpacing: 1.1),
              ),
            ),
            pw.Expanded(child: pw.Container(height: 0.8, color: PdfColors.grey300)),
          ],
        );

    pw.Widget infoRow(String labelEn, String value) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Expanded(
                child: pw.Text(pdfText(value),
                    style: pw.TextStyle(font: cairo, fontSize: 12, height: 1.35),
                    textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 14),
            pw.Text(labelEn,
                style:
                    pw.TextStyle(font: cairoBold, fontSize: 12, height: 1.35),
                textAlign: pw.TextAlign.left),
          ],
        );

    doc.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        header: (_) => pw.Column(
          children: [
            _buildHeader(logoData, cairo, cairoBold, clinic),
            pw.SizedBox(height: 8),
            pw.Container(height: 1, color: PdfColors.grey500),
          ],
        ),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
            border:
                pw.Border(top: pw.BorderSide(width: 0.6, color: PdfColors.grey300)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.Text(
                pdfText(
                    '${clinic.nameAr} - ${clinic.addressAr} - هاتف: ${clinic.phone}'),
                style: pw.TextStyle(
                    font: cairo, fontSize: 9, color: PdfColors.blueGrey),
              ),
              pw.SizedBox(width: 8),
              pw.Directionality(
                textDirection: pw.TextDirection.ltr,
                child: pw.Text(
                  'Page ${ctx.pageNumber}/${ctx.pagesCount}',
                  style: pw.TextStyle(
                      font: cairo, fontSize: 9, color: PdfColors.blueGrey),
                ),
              ),
            ],
          ),
        ),
        build: (_) => [
          pw.SizedBox(height: 10),
          sectionTitle('PRESCRIPTION'),
          pw.SizedBox(height: 10),
          infoRow('Patient Name', patient.name),
          thinDivider(),
          infoRow('Age', '${patient.age}'),
          thinDivider(),
          if (patient.phoneNumber.isNotEmpty)
            infoRow('Phone', patient.phoneNumber)
          else
            infoRow('Phone', '—'),
          if (doctor != null) ...[
            thinDivider(),
            infoRow('Doctor Name', doctor.name),
          ],
          thinDivider(),
          infoRow('Date', DateFormat('yyyy-MM-dd').format(recordDate)),
          pw.SizedBox(height: 18),
          pw.Row(
            children: [
              pw.Expanded(
                  child: pw.Container(height: 0.6, color: PdfColors.grey300)),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8),
                child: pw.Text('Medications',
                    style: pw.TextStyle(font: cairoBold, fontSize: 14)),
              ),
              pw.Expanded(
                  child: pw.Container(height: 0.6, color: PdfColors.grey300)),
            ],
          ),
          pw.SizedBox(height: 6),
          _buildTable(cairo, cairoBold, tableHeaders, items),
        ],
      ),
    );

    return doc.save();
  }

/*──────────────────────── تصدير قائمة كاملة ────────────────────────*/
  /// يقبل مصفوفة من السجلات تحتوي على:
  /// id, patientName, phone, doctorName, recordDate
  static Future<Uint8List> exportList(List<dynamic> records) async {
    final fonts = await loadPdfFonts();
    final cairo = fonts.regular;

    final headers = ['#', 'المريض', 'الهاتف', 'الطبيب', 'التاريخ'];

    final data = <List<String>>[];
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      data.add([
        '${i + 1}',
        pdfText('${r.patientName}'),
        '${r.phone}',
        pdfText(r.doctorName ?? '—'),
        DateFormat('yyyy-MM-dd').format(r.recordDate as DateTime),
      ]);
    }

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(20),
        build: (_) => [
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Column(
              children: [
                pw.Text(pdfText('قائمة الوصفات الطبية'),
                    style: pw.TextStyle(
                        font: cairo,
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                        color: kAccent)),
                pw.SizedBox(height: 20),
                pw.TableHelper.fromTextArray(
                  headers: headers.map(pdfText).toList(),
                  data: data,
                  headerStyle: pw.TextStyle(
                      font: cairo,
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold),
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
          )
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

    await Printing.sharePdf(
      bytes: bytes,
      filename:
          'prescription_${patient.id}_${DateFormat('yyyyMMdd').format(recordDate)}.pdf',
    );
  }

/*──────────────────────── عناصر البناء الخاصة ─────────────────*/
  static pw.Widget _buildHeader(
    Uint8List logo,
    pw.Font cairo,
    pw.Font cairoBold,
    ClinicProfile clinic,
  ) =>
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.only(right: 12),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(pdfText(clinic.nameAr),
                      style: pw.TextStyle(
                          font: cairoBold,
                          fontSize: 14,
                          color: PdfColors.blueGrey)),
                  pw.Text(pdfText(clinic.addressAr),
                      style: pw.TextStyle(font: cairo, fontSize: 9)),
                  pw.Text(pdfText('هاتف: ${clinic.phone}'),
                      style: pw.TextStyle(font: cairo, fontSize: 9)),
                ],
              ),
            ),
          ),
          pw.Container(
            width: 100,
            height: 60,
            alignment: pw.Alignment.topCenter,
            child: pw.Image(pw.MemoryImage(logo), width: 56, height: 56),
          ),
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.only(left: 12),
              child: pw.Directionality(
                textDirection: pw.TextDirection.ltr,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(clinic.nameEn,
                        textAlign: pw.TextAlign.left,
                        style: pw.TextStyle(
                            font: cairoBold,
                            fontSize: 14,
                            color: PdfColors.blueGrey)),
                    pw.Text(clinic.addressEn,
                        textAlign: pw.TextAlign.left,
                        style: pw.TextStyle(font: cairo, fontSize: 9)),
                    pw.Text('Tel: ${clinic.phone}',
                        textAlign: pw.TextAlign.left,
                        style: pw.TextStyle(font: cairo, fontSize: 9)),
                  ],
                ),
              ),
            ),
          ),
        ],
      );

  static pw.Widget _buildTable(
    pw.Font cairo,
    pw.Font cairoBold,
    List<String> headers,
    List<Map<String, dynamic>> items,
  ) {
    final data = <List<String>>[];
    for (final it in items) {
      final drug = it['drug'] as Drug;
      final days = it['days'] as int;
      final times = it['times'] as int;
      data.add([pdfText(drug.name), '$days', '$times']);
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
