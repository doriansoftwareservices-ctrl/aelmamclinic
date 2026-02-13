import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_report.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';

const PdfColor kReportAccent = PdfColor.fromInt(0xFF004A61);

class PatientReportPdfService {
  static Future<Uint8List> buildPdf({
    required Patient patient,
    required PatientReport report,
  }) async {
    pw.Font cairo;
    pw.Font cairoBold;
    try {
      final fontData = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
      final fontBold = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
      cairo = pw.Font.ttf(fontData.buffer.asByteData());
      cairoBold = pw.Font.ttf(fontBold.buffer.asByteData());
    } catch (_) {
      cairo = pw.Font.helvetica();
      cairoBold = pw.Font.helveticaBold();
    }

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

    pw.Widget infoRow(String labelEn, String value) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Expanded(
                child: pw.Text(value,
                    style: baseText, textAlign: pw.TextAlign.right)),
            pw.SizedBox(width: 14),
            pw.Text(labelEn, style: boldText, textAlign: pw.TextAlign.left),
          ],
        );

    doc.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        header: (_) => pw.Column(
          children: [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.only(right: 12),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(clinic.nameAr,
                            style: pw.TextStyle(
                                font: cairoBold,
                                fontSize: 14,
                                color: PdfColors.blueGrey)),
                        pw.Text(clinic.addressAr,
                            style: pw.TextStyle(font: cairo, fontSize: 9)),
                        pw.Text('الهاتف: ${clinic.phone}',
                            style: pw.TextStyle(font: cairo, fontSize: 9)),
                      ],
                    ),
                  ),
                ),
                pw.Container(
                  width: 100,
                  height: 60,
                  alignment: pw.Alignment.topCenter,
                  child: logoData == null
                      ? pw.SizedBox()
                      : pw.Image(pw.MemoryImage(logoData), width: 56, height: 56),
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
            ),
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
          child: pw.Text(
            '${clinic.nameAr} - ${clinic.addressAr} "هاتف : ${clinic.phone}  •  Page ${ctx.pageNumber}/${ctx.pagesCount}',
            style: pw.TextStyle(
                font: cairo, fontSize: 9, color: PdfColors.blueGrey),
            textAlign: pw.TextAlign.center,
          ),
        ),
        build: (_) => [
          pw.SizedBox(height: 10),
          _buildTitleRow(cairoBold, report),
          pw.SizedBox(height: 10),
          infoRow('Patient Name', patient.name),
          thinDivider(),
          infoRow('Age', '${patient.age}'),
          if (complaintTitle.isNotEmpty) ...[
            thinDivider(),
            infoRow('Complaint', complaintTitle),
          ],
          pw.SizedBox(height: 14),
          pw.Center(
            child: pw.Container(
              width: 420,
              child: _buildReportText(cairo, cairoBold, report.reportText),
            ),
          ),
          pw.SizedBox(height: 18),
          _buildFooter(cairo, clinic),
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
    await Printing.sharePdf(
      bytes: bytes,
      filename: 'patient_report_${patient.id}_$stamp.pdf',
    );
  }

  static pw.Widget _buildHeader(
    Uint8List logo,
    pw.Font cairo,
    pw.Font cairoBold,
    ClinicProfile clinic,
  ) {
    return pw.Row(
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(clinic.nameAr,
                  style: pw.TextStyle(
                      font: cairoBold,
                      fontSize: 14,
                      color: kReportAccent)),
              pw.Text(clinic.addressAr,
                  style: pw.TextStyle(font: cairo, fontSize: 9)),
              pw.Text('هاتف: ${clinic.phone}',
                  style: pw.TextStyle(font: cairo, fontSize: 9)),
            ],
          ),
        ),
        pw.Image(pw.MemoryImage(logo), width: 60, height: 60),
        pw.Expanded(
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
                        color: kReportAccent)),
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
      ],
    );
  }

  static pw.Widget _buildTitleRow(pw.Font bold, PatientReport report) {
    final date = report.createdAt != null
        ? DateFormat('yyyy-MM-dd • HH:mm').format(report.createdAt!.toLocal())
        : DateFormat('yyyy-MM-dd').format(DateTime.now());
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('التاريخ: $date',
            style: pw.TextStyle(font: bold, fontSize: 11)),
        pw.Text('',
            style: pw.TextStyle(font: bold, fontSize: 16, color: kReportAccent)),
      ],
    );
  }

  static pw.Widget _buildPatientInfo(
    pw.Font base,
    pw.Font bold,
    Patient patient,
  ) {
    pw.Widget row(String label, String value) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Expanded(
                child: pw.Text(value,
                    style: pw.TextStyle(font: base, fontSize: 11))),
            pw.SizedBox(width: 12),
            pw.Text(label, style: pw.TextStyle(font: bold, fontSize: 11)),
          ],
        );

    return pw.Column(
      children: [
        row('اسم المريض', patient.name),
        pw.SizedBox(height: 4),
        row('رقم الهاتف', patient.phoneNumber.isEmpty ? '—' : patient.phoneNumber),
        pw.SizedBox(height: 4),
        row('العمر', '${patient.age}'),
      ],
    );
  }

  static pw.Widget _buildReportText(
    pw.Font base,
    pw.Font bold,
    String reportText,
  ) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(reportText.isEmpty ? '—' : reportText,
              style: pw.TextStyle(font: base, fontSize: 11, height: 1.4),
              textAlign: pw.TextAlign.center),
        ],
      ),
    );
  }

  static pw.Widget _buildQuestionsTable(
    pw.Font base,
    pw.Font bold,
    List questions,
  ) {
    String answerLabel(dynamic v) {
      if (v == true) return 'نعم';
      if (v == false) return 'لا';
      return 'غير مجاب';
    }

    final headers = ['السؤال', 'الإجابة', 'الملاحظة'];
    final data = <List<String>>[];
    for (final q in questions) {
      if (q is! Map) continue;
      final text = (q['question_text'] ?? '').toString();
      final answer = answerLabel(q['answer']);
      final note = (q['note'] ?? '').toString();
      data.add([text, answer, note]);
    }

    if (data.isEmpty) {
      data.add(['—', '—', '—']);
    }

    return pw.Table(
      columnWidths: const <int, pw.TableColumnWidth>{
        0: pw.FlexColumnWidth(3.6),
        1: pw.FlexColumnWidth(1.3),
        2: pw.FlexColumnWidth(2.1),
      },
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(8),
              child: pw.Text(headers[0],
                  style: pw.TextStyle(font: bold, fontSize: 11),
                  textAlign: pw.TextAlign.right),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.all(8),
              child: pw.Text(headers[1],
                  style: pw.TextStyle(font: bold, fontSize: 11),
                  textAlign: pw.TextAlign.center),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.all(8),
              child: pw.Text(headers[2],
                  style: pw.TextStyle(font: bold, fontSize: 11),
                  textAlign: pw.TextAlign.right),
            ),
          ],
        ),
        for (final row in data)
          pw.TableRow(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.all(8),
                child: pw.Text(row[0],
                    style: pw.TextStyle(font: base, fontSize: 10),
                    textAlign: pw.TextAlign.right),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(8),
                child: pw.Text(row[1],
                    style: pw.TextStyle(font: base, fontSize: 10),
                    textAlign: pw.TextAlign.center),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(8),
                child: pw.Text(row[2],
                    style: pw.TextStyle(font: base, fontSize: 10),
                    textAlign: pw.TextAlign.right),
              ),
            ],
          ),
      ],
    );
  }

  static pw.Widget _buildFooter(pw.Font base, ClinicProfile clinic) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text('الطبيب: ____________________',
            style: pw.TextStyle(font: base, fontSize: 10)),
        pw.Text('التوقيع: ____________________',
            style: pw.TextStyle(font: base, fontSize: 10)),
      ],
    );
  }
}
