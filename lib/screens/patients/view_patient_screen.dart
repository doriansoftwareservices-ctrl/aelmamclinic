/* ── lib/screens/patients/view_patient_screen.dart ───────────────────────────── */

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;

/*── نمط TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_service.dart';
import 'package:aelmamclinic/models/attachment.dart';
import 'package:aelmamclinic/services/db_service.dart';

class ViewPatientScreen extends StatefulWidget {
  final Patient patient;
  const ViewPatientScreen({super.key, required this.patient});

  @override
  State<ViewPatientScreen> createState() => _ViewPatientScreenState();
}

class _ViewPatientScreenState extends State<ViewPatientScreen> {
  late final DateTime _registerDate;
  late final TimeOfDay _registerTime;
  late final String _serviceType; // للعرض بالعربي
  late final double _doctorShare;
  late final double _doctorInput;
  late Future<List<PatientService>> _servicesFuture;
  late Future<List<Attachment>> _attachmentsFuture;
  bool _reviewPending = false;
  DateTime? _doctorReviewedAt;
  bool _markingReview = false;

  final _dateOnly = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    final p = widget.patient;

    // إن لم يكن للمريض id نغلق الصفحة بأمان ونمنع أي استعلامات DB
    if (p.id == null) {
      _servicesFuture = Future.value(<PatientService>[]);
      _attachmentsFuture = Future.value(<Attachment>[]);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('المريض غير محفوظ بعد (لا يملك رقم تعريف).')),
        );
        Navigator.pop(context);
      });
    } else {
      _servicesFuture = DBService.instance.getPatientServices(p.id!);
      _attachmentsFuture = DBService.instance.getAttachmentsByPatient(p.id!);
    }

    _registerDate = p.registerDate;
    _registerTime = TimeOfDay.fromDateTime(p.registerDate);

    // عرض نوع الخدمة بالعربي حتى لو تم حفظها ككود بعد المزامنة
    _serviceType = _serviceTypePretty(p.serviceType);

    _doctorShare = p.doctorShare;
    _doctorInput = p.doctorInput;
    _reviewPending = p.doctorReviewPending;
    _doctorReviewedAt = p.doctorReviewedAt;
  }

  Future<void> _markPatientReviewed() async {
    if (_markingReview || widget.patient.id == null) return;
    setState(() => _markingReview = true);
    try {
      await DBService.instance.markPatientReviewed(widget.patient.id!);
      if (!mounted) return;
      setState(() {
        _reviewPending = false;
        _doctorReviewedAt = DateTime.now();
        _markingReview = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تسجيل مقابلة المريض.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحديث الحالة: $e')),
      );
      setState(() => _markingReview = false);
    }
  }

  // تحويل كود نوع الخدمة إلى نص عربي
  String _serviceTypePretty(String? code) {
    switch ((code ?? '').trim().toLowerCase()) {
      case 'radiology':
        return 'الأشعة';
      case 'lab':
        return 'المختبر';
      case 'doctor':
        return 'طبيب';
      default:
        return (code == null || code.trim().isEmpty) ? '—' : code;
    }
  }

  // هل هناك وقت فعلي (ليس 00:00 الذي قد يأتي من عمود DATE فقط)؟
  bool _hasRealTime(DateTime dt) =>
      dt.hour != 0 || dt.minute != 0 || dt.second != 0;

  String _formatRegistrationDateTime() {
    final d = _dateOnly.format(_registerDate);
    if (_hasRealTime(_registerDate)) {
      final t = _registerTime.format(context);
      return '$d • $t';
    }
    return d; // لو الوقت مفقود بسبب المزامنة (DATE فقط)، نعرض التاريخ وحده
  }

  String? _formatDoctorReviewedAt() {
    final dt = _doctorReviewedAt;
    if (dt == null) return null;
    final date = _dateOnly.format(dt);
    if (_hasRealTime(dt)) {
      final time = TimeOfDay.fromDateTime(dt).format(context);
      return '$date • $time';
    }
    return date;
  }

  Future<void> _openAttachment(Attachment a) async {
    try {
      final exists = await File(a.filePath).exists();
      if (!exists) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('الملف غير موجود: ${a.fileName}')),
        );
        return;
      }
      await OpenFile.open(a.filePath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر فتح الملف: $e')),
      );
    }
  }

  /*────────────── أدوات PDF مساعدة ──────────────*/
  /*────────────── مولِّد PDF (Bytes) ──────────────*/
  Future<Uint8List> _buildPatientPdfBytes() async {
    final patient = widget.patient;

    // مفتاح عدّاد الطباعة فقط (لا يؤثر على عرض الاسم)
    String cleanDoctorKey(String? name) {
      if (name == null) return 'GENERAL';
      final s = name.trim();
      if (s.isEmpty) return 'GENERAL';
      return s.replaceFirst(
          RegExp(r'^\s*(د\/|د\\|د\.|دكتور|Doctor|Dr\.?)\s*',
              caseSensitive: false),
          '');
    }

    final displayDoctorName = (patient.doctorName?.trim().isNotEmpty ?? false)
        ? patient.doctorName!.trim()
        : '---';
    final counterKey = cleanDoctorKey(patient.doctorName);

    // رقم الإيصال التالي
    final docCounter =
        await DBService.instance.getNextPrintCounterForDoctor(counterKey);
    final counterStr = docCounter.toString();

    // الخطوط والشعار
    pw.Font cairoRegular;
    pw.Font cairoBold;
    Uint8List? logo;
    try {
      final fReg = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
      final fBold = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
      cairoRegular = pw.Font.ttf(fReg.buffer.asByteData());
      cairoBold = pw.Font.ttf(fBold.buffer.asByteData());
    } catch (_) {
      // احتياط في حال غابت الملفات
      cairoRegular = pw.Font.helvetica();
      cairoBold = pw.Font.helveticaBold();
    }
    try {
      final logoBytes = await rootBundle.load('assets/images/logo2.png');
      logo = logoBytes.buffer.asUint8List();
    } catch (_) {
      logo = null;
    }

    // الخدمات والمرفقات
    final services = await _servicesFuture;
    final serviceRows = services
        .map((s) => [s.serviceCost.toStringAsFixed(2), s.serviceName])
        .toList();

    // إجمالي الخدمات: إن لم توجد صفوف خدمات (أحياناً بعد مزامنة قد تغيب التفاصيل)،
    // استخدم (المدفوع + المتبقي) كهجينة حتى لا يضيع الإجمالي في الوثيقة.
    double totalCost = services.fold<double>(0.0, (p, s) => p + s.serviceCost);
    if (serviceRows.isEmpty) {
      totalCost = (patient.paidAmount + patient.remaining);
    }

    final attachments = await _attachmentsFuture;

    final pdf = pw.Document();

    final baseText =
        pw.TextStyle(font: cairoRegular, fontSize: 12, height: 1.35);
    final boldText = pw.TextStyle(font: cairoBold, fontSize: 12, height: 1.35);

    // صفحة A4
    final pageTheme = pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(20),
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: cairoRegular, bold: cairoBold),
    );

    pw.Widget thinDivider([double v = 6]) => pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: v),
          child: pw.Container(height: 0.7, color: PdfColors.grey300),
        );

    // سطر معلومات: العنوان (إنجليزي) يسار، والقيمة يمين
    pw.Widget infoRow(String labelEn, String value, {bool isRecordNo = false}) {
      final valueStyle = isRecordNo
          ? pw.TextStyle(
              font: cairoBold, fontSize: 13, color: PdfColors.red, height: 1.4)
          : baseText;
      return pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Expanded(
              child: pw.Text(value,
                  style: valueStyle, textAlign: pw.TextAlign.right)),
          pw.SizedBox(width: 14),
          pw.Text(labelEn, style: boldText, textAlign: pw.TextAlign.left),
        ],
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        header: (_) => pw.Column(
          children: [
            // أعلى الصفحة: عربي يمين – شعار – إنجليزي يسار
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                // الإنجليزية — يسار الصفحة
                pw.Expanded(
                  child: pw.Padding(
                    padding:
                        const pw.EdgeInsets.only(right: 12), // إبعاد عن الشعار
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('مركز إلمام الطبي',
                            style: pw.TextStyle(
                                font: cairoBold,
                                fontSize: 14,
                                color: PdfColors.blueGrey)),
                        pw.Text('العنوان1 - العنوان2 - العنوان3',
                            style:
                                pw.TextStyle(font: cairoRegular, fontSize: 9)),
                        pw.Text('الهاتف: 12345678',
                            style:
                                pw.TextStyle(font: cairoRegular, fontSize: 9)),
                      ],
                    ),
                  ),
                ),
                // الشعار في الوسط
                pw.Container(
                  width: 100,
                  height: 60,
                  alignment: pw.Alignment.topCenter,
                  child: logo == null
                      ? pw.SizedBox()
                      : pw.Image(pw.MemoryImage(logo), width: 56, height: 56),
                ),
                // العربية — يمين الصفحة
                pw.Expanded(
                  child: pw.Padding(
                    padding:
                        const pw.EdgeInsets.only(left: 12), // إبعاد عن الشعار
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('Elmam Health Center',
                            style: pw.TextStyle(
                                font: cairoBold,
                                fontSize: 14,
                                color: PdfColors.blueGrey)),
                        pw.Text('Address1 – Address2 - Address3',
                            style:
                                pw.TextStyle(font: cairoRegular, fontSize: 9)),
                        pw.Text('Tel: 12345678',
                            style:
                                pw.TextStyle(font: cairoRegular, fontSize: 9)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // فاصل علوي واضح
            pw.SizedBox(height: 8),
            pw.Container(height: 1, color: PdfColors.grey500),
          ],
        ),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
                top: pw.BorderSide(width: 0.6, color: PdfColors.grey300)),
          ),
          child: pw.Text(
            'مركز إلمام الطبي - العنوان1 - العنوان2 - العنوان3 "هاتف : 12345678  •  Page ${ctx.pageNumber}/${ctx.pagesCount}',
            style: pw.TextStyle(
                font: cairoRegular, fontSize: 9, color: PdfColors.blueGrey),
            textAlign: pw.TextAlign.center,
          ),
        ),
        build: (_) => [
          pw.SizedBox(height: 10),

          // عنوان PATIENT DETAILS
          pw.Row(
            children: [
              pw.Expanded(
                  child: pw.Container(height: 0.8, color: PdfColors.grey300)),
              pw.Container(
                margin: const pw.EdgeInsets.symmetric(horizontal: 8),
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey100,
                  border: pw.Border.all(color: PdfColors.grey400, width: 0.8),
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Text(
                  'PATIENT DETAILS',
                  style: pw.TextStyle(
                      font: cairoBold, fontSize: 15, letterSpacing: 1.1),
                ),
              ),
              pw.Expanded(
                  child: pw.Container(height: 0.8, color: PdfColors.grey300)),
            ],
          ),
          pw.SizedBox(height: 10),

          // معلومات أساسية
          infoRow('Record No.', counterStr, isRecordNo: true),
          thinDivider(),
          infoRow('Registration Date', _formatRegistrationDateTime()),
          thinDivider(),
          infoRow('Patient Name', patient.name),
          thinDivider(),
          infoRow('Age', patient.age.toString()),
          thinDivider(),
          infoRow(
              'Phone', patient.phoneNumber.isEmpty ? '—' : patient.phoneNumber),
          thinDivider(),
          infoRow(
              'Service Type', _serviceType), // ← أضفنا نوع الخدمة في الـ PDF
          if (displayDoctorName != '---') ...[
            thinDivider(),
            infoRow('Doctor Name', displayDoctorName),
          ],
          if ((patient.doctorShare ?? 0) > 0) ...[
            thinDivider(),
            infoRow('Doctor Share (Radiology/Lab)',
                (patient.doctorShare).toStringAsFixed(2)),
          ],

          pw.SizedBox(height: 18),

          // عنوان جدول الخدمات
          pw.Row(
            children: [
              pw.Expanded(
                  child: pw.Container(height: 0.6, color: PdfColors.grey300)),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8),
                child: pw.Text('Services',
                    style: pw.TextStyle(font: cairoBold, fontSize: 14)),
              ),
              pw.Expanded(
                  child: pw.Container(height: 0.6, color: PdfColors.grey300)),
            ],
          ),
          pw.SizedBox(height: 6),

          // جدول الخدمات
          pw.Table(
            columnWidths: const <int, pw.TableColumnWidth>{
              0: pw.FlexColumnWidth(1),
              1: pw.FlexColumnWidth(3),
            },
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text('Price',
                        style: boldText, textAlign: pw.TextAlign.center),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text('Service',
                        style: boldText, textAlign: pw.TextAlign.right),
                  ),
                ],
              ),
              if (serviceRows.isNotEmpty)
                for (final r in serviceRows)
                  pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(r[0],
                            style: baseText, textAlign: pw.TextAlign.center),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(r[1],
                            style: baseText, textAlign: pw.TextAlign.right),
                      ),
                    ],
                  )
              else
                // لو لا توجد خدمات (حالة مزامنة)، نظهر صفًا شكليًا بدل الجدول الفارغ
                pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(8),
                      child: pw.Text('—',
                          style: baseText, textAlign: pw.TextAlign.center),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(8),
                      child: pw.Text('لا توجد خدمات مسجلة',
                          style: baseText, textAlign: pw.TextAlign.right),
                    ),
                  ],
                ),
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(
                      totalCost.toStringAsFixed(2),
                      style: pw.TextStyle(
                          font: cairoBold,
                          fontSize: 12,
                          color: PdfColors.green700),
                      textAlign: pw.TextAlign.center,
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text('Total',
                        style: pw.TextStyle(
                            font: cairoBold,
                            fontSize: 12,
                            color: PdfColors.green700),
                        textAlign: pw.TextAlign.right),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    // صفحات المرفقات (صور فقط)
    for (final a in attachments) {
      try {
        final file = File(a.filePath);
        final isImage = a.mimeType.startsWith('image/');
        if (await file.exists() && isImage) {
          final bytes = await file.readAsBytes();
          final img = pw.MemoryImage(bytes);
          pdf.addPage(
            pw.Page(
              pageTheme: pageTheme,
              build: (_) => pw.Center(
                child: pw.FittedBox(
                  fit: pw.BoxFit.contain,
                  child: pw.Image(img),
                ),
              ),
            ),
          );
        }
      } catch (_) {
        // تجاهل المرفق غير القابل للقراءة
      }
    }

    return pdf.save();
  }

  /*────────────── تصدير / طباعة ──────────────*/
  Future<void> _exportToPdf() async {
    try {
      final bytes = await _buildPatientPdfBytes();
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'patient_${widget.patient.id}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء إنشاء PDF: $e')),
      );
    }
  }

  Future<void> _printPdf() async {
    try {
      await Printing.layoutPdf(onLayout: (_) async => _buildPatientPdfBytes());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّرت الطباعة: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasDoctor = (widget.patient.doctorName?.trim().isNotEmpty ?? false);
    final hasId = widget.patient.id != null;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/logo.png',
                height: 24,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
              const Text('ELMAM CLINIC'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'تصدير PDF',
              icon: const Icon(Icons.picture_as_pdf),
              onPressed: hasId ? _exportToPdf : null,
            ),
            IconButton(
              tooltip: 'طباعة',
              icon: const Icon(Icons.print),
              onPressed: hasId ? _printPdf : null,
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_reviewPending && hasId)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: FilledButton.icon(
                      onPressed:
                          _markingReview ? null : () => _markPatientReviewed(),
                      icon: const Icon(Icons.verified),
                      label: const Text('تم مقابلة المريض'),
                    ),
                  ),
                _SectionHeader(title: 'Registration', color: scheme.primary),
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: _InfoTile(
                    icon: Icons.calendar_today,
                    label: 'تاريخ ووقت التسجيل',
                    value: _formatRegistrationDateTime(),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionHeader(title: 'Patient Info', color: scheme.primary),
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Column(
                    children: [
                      _InfoTile(
                          icon: Icons.person,
                          label: 'اسم المريض',
                          value: widget.patient.name),
                      const Divider(height: 12),
                      _InfoTile(
                          icon: Icons.cake,
                          label: 'العمر',
                          value: widget.patient.age.toString()),
                      const Divider(height: 12),
                      _InfoTile(
                          icon: Icons.phone,
                          label: 'رقم الهاتف',
                          value: widget.patient.phoneNumber.isEmpty
                              ? '—'
                              : widget.patient.phoneNumber),
                      if (hasDoctor) ...[
                        const Divider(height: 12),
                        _InfoTile(
                            icon: Icons.local_hospital,
                            label: 'الطبيب',
                            value: widget.patient.doctorName!.trim()),
                      ],
                      if (_doctorReviewedAt != null) ...[
                        const Divider(height: 12),
                        _InfoTile(
                          icon: Icons.verified_user,
                          label: 'آخر تأكيد للطبيب',
                          value: _formatDoctorReviewedAt() ?? '—',
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SectionHeader(title: 'Service', color: scheme.primary),
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InfoTile(
                        icon: Icons.miscellaneous_services,
                        label: 'نوع الخدمة',
                        value: _serviceType,
                      ),
                      const SizedBox(height: 8),
                      FutureBuilder<List<PatientService>>(
                        future: _servicesFuture,
                        builder: (ctx, snap) {
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: LinearProgressIndicator(),
                            );
                          }
                          final svcs = snap.data ?? const <PatientService>[];
                          if (svcs.isEmpty) {
                            // حالة مزامنة بدون تفاصيل خدمات: نعرض توضيح + إجمالي من (مدفوع+متبقي)
                            final fallbackTotal = (widget.patient.paidAmount +
                                    widget.patient.remaining)
                                .toStringAsFixed(2);
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                    'لا توجد خدمات مسجلة (قد تكون أتت من المزامنة بدون تفاصيل).'),
                                const SizedBox(height: 8),
                                _InfoTile(
                                  icon: Icons.summarize,
                                  label: 'إجمالي تكلفة الخدمات',
                                  value: fallbackTotal,
                                ),
                              ],
                            );
                          }
                          final total =
                              svcs.fold<double>(0, (p, e) => p + e.serviceCost);

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: svcs
                                    .map(
                                      (s) => Chip(
                                        backgroundColor: kPrimaryColor
                                            .withValues(alpha: .10),
                                        label: Text(
                                            '${s.serviceName} • ${s.serviceCost.toStringAsFixed(2)}'),
                                      ),
                                    )
                                    .toList(),
                              ),
                              const SizedBox(height: 8),
                              _InfoTile(
                                icon: Icons.summarize,
                                label: 'إجمالي تكلفة الخدمات',
                                value: total.toStringAsFixed(2),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SectionHeader(title: 'Financials', color: scheme.primary),
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Column(
                    children: [
                      _InfoTile(
                        icon: Icons.attach_money,
                        label: 'المبلغ المقدم',
                        value: widget.patient.paidAmount.toStringAsFixed(2),
                      ),
                      const Divider(height: 12),
                      _InfoTile(
                        icon: Icons.money_off,
                        label: 'المبلغ المتبقي',
                        value: widget.patient.remaining.toStringAsFixed(2),
                      ),
                      if (_doctorShare > 0) ...[
                        const Divider(height: 12),
                        _InfoTile(
                          icon: Icons.share,
                          label: 'حصة الطبيب (الأشعة/المختبر)',
                          value: _doctorShare.toStringAsFixed(2),
                        ),
                      ],
                      if (_doctorInput > 0) ...[
                        const Divider(height: 12),
                        _InfoTile(
                          icon: Icons.input,
                          label: 'مدخلات الطبيب',
                          value: _doctorInput.toStringAsFixed(2),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _SectionHeader(title: 'Notes', color: scheme.primary),
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: _InfoTile(
                    icon: Icons.note,
                    label: 'ملاحظات',
                    value: (widget.patient.notes?.trim().isEmpty ?? true)
                        ? '—'
                        : widget.patient.notes!.trim(),
                    maxLines: 4,
                  ),
                ),
                const SizedBox(height: 14),
                _SectionHeader(title: 'Attachments', color: scheme.primary),
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: FutureBuilder<List<Attachment>>(
                    future: _attachmentsFuture,
                    builder: (ctx, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: LinearProgressIndicator(),
                        );
                      }
                      if (!snap.hasData || snap.data!.isEmpty) {
                        return const Text('لا توجد مرفقات');
                      }
                      final atts = snap.data!;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: atts.map((a) {
                          final isImage = a.mimeType.startsWith('image/');
                          return InkWell(
                            onTap: () => _openAttachment(a),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: kPrimaryColor.withValues(alpha: .10),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color:
                                        kPrimaryColor.withValues(alpha: .25)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isImage
                                        ? Icons.image
                                        : Icons.insert_drive_file,
                                    size: 18,
                                    color: kPrimaryColor,
                                  ),
                                  const SizedBox(width: 6),
                                  ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 220),
                                    child: Text(
                                      a.fileName,
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.picture_as_pdf),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: hasId ? _exportToPdf : null,
                        label: const Text('تصدير PDF'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.print),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: hasId ? _printPdf : null,
                        label: const Text('طباعة'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('رجوع'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/*──────── رأس قسم ────────*/
class _SectionHeader extends StatelessWidget {
  final String title;
  final Color color;
  const _SectionHeader({required this.title, required this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
      );
}

/*──────── عنصر معلومات داخل بطاقة ────────*/
class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final int maxLines;
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.maxLines = 1,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      minLeadingWidth: 0,
      leading: Container(
        decoration: BoxDecoration(
          color: kPrimaryColor.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: kPrimaryColor, size: 20),
      ),
      title: Text(
        label,
        style: TextStyle(
          color: scheme.onSurface.withValues(alpha: .85),
          fontWeight: FontWeight.w800,
        ),
      ),
      subtitle: Text(
        value,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurface),
      ),
    );
  }
}
