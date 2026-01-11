// lib/services/prescription_pdf_service.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'package:aelmamclinic/models/clinic_profile.dart'; // ✅ مهم
import 'package:aelmamclinic/models/drug.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';

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
    final fontData = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    final cairo = pw.Font.ttf(fontData.buffer.asByteData());

    // الشعار
    final logoData =
        (await rootBundle.load('assets/images/logo2.png')).buffer.asUint8List();

    final clinic = await ClinicProfileService.loadActiveOrFallback();

    // رأس الجدول
    const tableHeaders = ['الدواء', 'أيام', 'مرّات/يوم'];

    // بناء الوثيقة
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(20),
        build: (_) => [
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                _buildHeader(logoData, cairo, clinic),
                pw.SizedBox(height: 16),
                _buildPatientInfo(cairo, patient, doctor, recordDate),
                pw.SizedBox(height: 16),
                _buildTable(cairo, tableHeaders, items),
                pw.SizedBox(height: 24),
                _buildFooter(cairo, clinic),
              ],
            ),
          ),
        ],
      ),
    );

    return doc.save();
  }

  /*──────────────────────── تصدير قائمة كاملة ────────────────────────*/
  /// يقبل مصفوفة من السجلات تحتوي على:
  /// id, patientName, phone, doctorName, recordDate
  static Future<Uint8List> exportList(List<dynamic> records) async {
    final fontData = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    final cairo = pw.Font.ttf(fontData.buffer.asByteData());

    const headers = ['#', 'المريض', 'الهاتف', 'الطبيب', 'التاريخ'];

    final data = <List<String>>[];
    for (var i = 0; i < records.length; i++) {
      final r = records[i];

      // دعم بسيط لو r كان Map أو Object فيه getters
      String read(dynamic obj, String key) {
        if (obj is Map) return (obj[key] ?? '').toString();
        try {
          // ignore: avoid_dynamic_calls
          return (obj as dynamic).__getattribute__(key).toString();
        } catch (_) {
          // fallback: جرّب dot access بدون تعقيد
          try {
            // ignore: avoid_dynamic_calls
            final v = (obj as dynamic)[key];
            return (v ?? '').toString();
          } catch (_) {
            return '';
          }
        }
      }

      DateTime? readDate(dynamic obj) {
        if (obj is Map) {
          final v = obj['recordDate'];
          if (v is DateTime) return v;
          return DateTime.tryParse(v?.toString() ?? '');
        }
        try {
          // ignore: avoid_dynamic_calls
          final v = (obj as dynamic).recordDate;
          if (v is DateTime) return v;
          return DateTime.tryParse(v?.toString() ?? '');
        } catch (_) {
          return null;
        }
      }

      final patientName = (r is Map)
          ? (r['patientName'] ?? '').toString()
          : (read(r, 'patientName'));
      final phone =
          (r is Map) ? (r['phone'] ?? '').toString() : (read(r, 'phone'));
      final doctorName = (r is Map)
          ? (r['doctorName'] ?? '—').toString()
          : ((read(r, 'doctorName').trim().isEmpty)
              ? '—'
              : read(r, 'doctorName'));
      final rd = readDate(r) ?? DateTime.now();

      data.add([
        '${i + 1}',
        patientName.isEmpty ? '—' : patientName,
        phone.isEmpty ? '—' : phone,
        doctorName,
        DateFormat('yyyy-MM-dd').format(rd),
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
                pw.Text(
                  'قائمة الوصفات الطبية',
                  style: pw.TextStyle(
                    font: cairo,
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                    color: kAccent,
                  ),
                ),
                pw.SizedBox(height: 20),
                pw.TableHelper.fromTextArray(
                  headers: headers,
                  data: data,
                  headerStyle: pw.TextStyle(
                    font: cairo,
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  cellStyle: pw.TextStyle(font: cairo, fontSize: 10),
                  headerDecoration: pw.BoxDecoration(color: kLightAccent),
                  cellAlignment: pw.Alignment.center,
                  columnWidths: const {
                    0: pw.FlexColumnWidth(1),
                    1: pw.FlexColumnWidth(3),
                    2: pw.FlexColumnWidth(2),
                    3: pw.FlexColumnWidth(3),
                    4: pw.FlexColumnWidth(2),
                  },
                ),
              ],
            ),
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

    await Printing.sharePdf(
      bytes: bytes,
      filename:
          'prescription_${patient.id}_${DateFormat('yyyyMMdd').format(recordDate)}.pdf',
    );
  }

  // ─────────────────────── Helpers (address formatting) ───────────────────────

  static String _joinParts(List<String> parts) {
    final cleaned =
        parts.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return cleaned.isEmpty ? '' : cleaned.join(' - ');
  }

  static String _addressAr(ClinicProfile c) =>
      _joinParts([c.cityAr, c.streetAr, c.nearAr]);

  static String _addressEn(ClinicProfile c) =>
      _joinParts([c.cityEn, c.streetEn, c.nearEn]);

  /*──────────────────────── عناصر البناء الخاصة ─────────────────*/
  static pw.Widget _buildHeader(
    Uint8List logo,
    pw.Font cairo,
    ClinicProfile clinic,
  ) {
    final addrAr = _addressAr(clinic);
    final addrEn = _addressEn(clinic);

    return pw.Row(
      children: [
        // ——— العربية (بداية السطر) ———
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                clinic.nameAr,
                style: pw.TextStyle(
                  font: cairo,
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  color: kAccent,
                ),
              ),
              if (addrAr.isNotEmpty)
                pw.Text(addrAr, style: pw.TextStyle(font: cairo, fontSize: 9)),
              if (clinic.phone.trim().isNotEmpty)
                pw.Text('هاتف: ${clinic.phone}',
                    style: pw.TextStyle(font: cairo, fontSize: 9)),
            ],
          ),
        ),

        pw.Image(pw.MemoryImage(logo), width: 60, height: 60),

        // ——— الإنجليزية (نهاية السطر) ———
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                clinic.nameEn,
                style: pw.TextStyle(
                  font: cairo,
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  color: kAccent,
                ),
              ),
              if (addrEn.isNotEmpty)
                pw.Text(addrEn, style: pw.TextStyle(font: cairo, fontSize: 9)),
              if (clinic.phone.trim().isNotEmpty)
                pw.Text('Tel: ${clinic.phone}',
                    style: pw.TextStyle(font: cairo, fontSize: 9)),
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildPatientInfo(
    pw.Font cairo,
    Patient patient,
    Doctor? doctor,
    DateTime recordDate,
  ) =>
      pw.Container(
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey, width: .5),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          color: PdfColors.grey200,
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'اسم المريض: ${patient.name}',
              style: pw.TextStyle(
                font: cairo,
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text('العمر: ${patient.age}',
                style: pw.TextStyle(font: cairo, fontSize: 11)),
            if (doctor != null)
              pw.Text('الطبيب: د/${doctor.name}',
                  style: pw.TextStyle(font: cairo, fontSize: 11)),
            pw.Text(
              'التاريخ: ${DateFormat('yyyy-MM-dd').format(recordDate)}',
              style: pw.TextStyle(font: cairo, fontSize: 11),
            ),
          ],
        ),
      );

  static pw.Widget _buildTable(
    pw.Font cairo,
    List<String> headers,
    List<Map<String, dynamic>> items,
  ) {
    final data = <List<String>>[];

    for (final it in items) {
      final drug = it['drug'] as Drug;
      final days = (it['days'] as num).toInt();
      final times = (it['times'] as num).toInt();
      data.add([drug.name, '$days', '$times']);
    }

    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: data,
      headerStyle: pw.TextStyle(
        font: cairo,
        fontWeight: pw.FontWeight.bold,
        fontSize: 11,
      ),
      cellStyle: pw.TextStyle(font: cairo, fontSize: 10),
      headerDecoration: pw.BoxDecoration(color: kLightAccent),
      cellAlignment: pw.Alignment.center,
      columnWidths: const {
        0: pw.FlexColumnWidth(4),
        1: pw.FlexColumnWidth(1),
        2: pw.FlexColumnWidth(1),
      },
    );
  }

  static pw.Widget _buildFooter(pw.Font cairo, ClinicProfile clinic) {
    final addrAr = _addressAr(clinic);
    final phone = clinic.phone.trim();

    final line = _joinParts([
      clinic.nameAr,
      addrAr,
      phone.isEmpty ? '' : 'هاتف: $phone',
    ]);

    return pw.Center(
      child: pw.Text(
        line.isEmpty ? clinic.nameAr : line,
        style: pw.TextStyle(font: cairo, fontSize: 9, color: kAccent),
      ),
    );
  }
}
