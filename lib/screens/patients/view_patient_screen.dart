/* ── lib/screens/patients/view_patient_screen.dart ───────────────────────────── */

import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:open_file/open_file.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

/*── نمط TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/core/features.dart';
import 'package:aelmamclinic/core/formatters.dart';

import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/models/drug.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_complaint.dart';
import 'package:aelmamclinic/models/patient_report.dart';
import 'package:aelmamclinic/models/prescription.dart';
import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/models/patient_service.dart';
import 'package:aelmamclinic/models/attachment.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/patient_questions_service.dart';
import 'package:aelmamclinic/services/patient_report_pdf_service.dart';
import 'package:aelmamclinic/services/prescription_pdf_service.dart';
import 'package:aelmamclinic/screens/patient_questions/patient_details_questions_section.dart';
import 'package:aelmamclinic/screens/patient_questions/patient_reports_list_screen.dart';
import 'package:aelmamclinic/screens/patient_questions/report_editor_screen.dart';
import 'package:aelmamclinic/screens/patient_questions/report_view_screen.dart';
import 'package:aelmamclinic/screens/prescriptions/new_prescription_screen.dart';
import 'package:aelmamclinic/screens/prescriptions/view_prescription_screen.dart';
import 'package:aelmamclinic/screens/returns/new_return_screen.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/utils/pdf_fonts.dart';
import 'package:aelmamclinic/utils/pdf_text.dart';
import 'package:aelmamclinic/utils/report_localizer.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class ViewPatientScreen extends StatefulWidget {
  final Patient patient;
  const ViewPatientScreen({super.key, required this.patient});

  @override
  State<ViewPatientScreen> createState() => _ViewPatientScreenState();
}

class _ViewPatientScreenState extends State<ViewPatientScreen> {
  late Patient _patient;
  late final DateTime _registerDate;
  late final TimeOfDay _registerTime;
  late final String _serviceType; // للعرض بالعربي
  late final double _doctorShare;
  late final double _doctorInput;
  late Future<List<PatientService>> _servicesFuture;
  late Future<List<Attachment>> _attachmentsFuture;
  final _questionsService = PatientQuestionsService();
  late Future<_PatientHistoryBundle> _patientHistoryFuture;
  late Future<_PatientReportsBundle> _patientReportsFuture;
  bool _reviewPending = false;
  DateTime? _doctorReviewedAt;
  bool _markingReview = false;
  bool _isDoctorUser = false;
  bool _launchingClinicalAction = false;
  _PatientRecordTab _selectedRecordTab = _PatientRecordTab.visits;
  int? _highlightPrescriptionId;

  DateFormat get _dateOnly => AppFormatters.dateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    final p = widget.patient;
    _patient = p;

    // إن لم يكن للمريض id نغلق الصفحة بأمان ونمنع أي استعلامات DB
    if (p.id == null) {
      _servicesFuture = Future.value(<PatientService>[]);
      _attachmentsFuture = Future.value(<Attachment>[]);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: LocalizedText('المريض غير محفوظ بعد (لا يملك رقم تعريف).')),
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

    _patientHistoryFuture = _loadPatientHistory();
    _patientReportsFuture = _loadPatientReports();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDoctorCapability();
    });
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
        const SnackBar(content: LocalizedText('تم تسجيل مقابلة المريض.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذر تحديث الحالة: $e')),
      );
      setState(() => _markingReview = false);
    }
  }

  Future<void> _showPaymentDialog() async {
    final p = _patient;
    if (p.id == null) return;
    if (p.remaining <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('لا يوجد مبلغ متبقٍ على المريض.')),
      );
      return;
    }
    final amountCtrl =
        TextEditingController(text: p.remaining.toStringAsFixed(2));
    final noteCtrl = TextEditingController();
    bool settleAll = false;
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const LocalizedText('تسديد مبلغ'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LocalizedText('المتبقي: ${p.remaining.toStringAsFixed(2)}'),
              const SizedBox(height: 8),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.trRaw('المبلغ المدفوع'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                decoration: InputDecoration(
                  labelText: context.trRaw('ملاحظة (اختياري)'),
                ),
              ),
              const SizedBox(height: 8),
              StatefulBuilder(
                builder: (ctx2, setState) => CheckboxListTile(
                  value: settleAll,
                  onChanged: (v) {
                    setState(() => settleAll = v ?? false);
                    if (settleAll) {
                      amountCtrl.text =
                          p.remaining.toStringAsFixed(2);
                    }
                  },
                  title: const LocalizedText('اعتبار المدفوع = الإجمالي'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const LocalizedText('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () async {
                final raw = amountCtrl.text.trim().replaceAll(',', '.');
                final amount = double.tryParse(raw) ?? 0.0;
                if (amount <= 0 && !settleAll) return;
                try {
                  await DBService.instance.applyPatientPayment(
                    patientId: p.id!,
                    amount: amount,
                    settleAll: settleAll,
                    note: noteCtrl.text.trim().isEmpty
                        ? null
                        : noteCtrl.text.trim(),
                  );
                  final fresh =
                      await DBService.instance.getPatientById(p.id!);
                  if (fresh != null && mounted) {
                    setState(() => _patient = fresh);
                    _refreshClinicalSections(refreshReports: false);
                  }
                  if (context.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: LocalizedText('تعذر التسديد: $e')),
                  );
                }
              },
              child: const LocalizedText('حفظ'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadDoctorCapability() async {
    final auth = context.read<AuthProvider>();
    final uid = auth.uid ?? '';
    if (uid.isEmpty) return;
    try {
      final emp = await DBService.instance.getEmployeeByUserUid(uid);
      if (!mounted) return;
      setState(() => _isDoctorUser = emp?.isDoctor ?? false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isDoctorUser = false);
    }
  }

  void _refreshClinicalSections({bool refreshReports = true}) {
    if (!mounted) return;
    setState(() {
      _patientHistoryFuture = _loadPatientHistory();
      if (refreshReports) {
        _patientReportsFuture = _loadPatientReports();
      }
    });
  }

  String _patientMatchKey(Patient patient) {
    final phone = Formatters.normalizePhone(patient.phoneNumber);
    if (phone.isNotEmpty) return 'PHONE:$phone';
    return 'NAME:${Formatters.normalizeForSearch(patient.name)}|AGE:${patient.age}';
  }

  bool _matchesReturnEntry(ReturnEntry entry) {
    final targetPhone = Formatters.normalizePhone(_patient.phoneNumber);
    if (targetPhone.isNotEmpty) {
      return Formatters.normalizePhone(entry.phoneNumber) == targetPhone;
    }
    return entry.age == _patient.age &&
        Formatters.normalizeForSearch(entry.patientName) ==
            Formatters.normalizeForSearch(_patient.name);
  }

  Future<_PatientHistoryBundle> _loadPatientHistory() async {
    final allPatients = await DBService.instance.getAllPatients();
    final matchKey = _patientMatchKey(_patient);

    final visits = allPatients
        .where((p) => _patientMatchKey(p) == matchKey)
        .toList()
      ..sort((a, b) => b.registerDate.compareTo(a.registerDate));

    if (_patient.id == null) {
      visits
        ..clear()
        ..add(_patient);
    } else if (!visits.any((p) => p.id == _patient.id)) {
      visits.insert(0, _patient);
    }

    final servicesByPatientId = <int, List<PatientService>>{};
    for (final visit in visits) {
      final visitId = visit.id;
      if (visitId == null) continue;
      servicesByPatientId[visitId] =
          await DBService.instance.getPatientServices(visitId);
    }

    final visitIds =
        visits.where((p) => p.id != null).map((p) => p.id!).toList();
    final prescriptions = <_PrescriptionHistoryEntry>[];
    if (visitIds.isNotEmpty) {
      final db = await DBService.instance.database;
      final placeholders = List.filled(visitIds.length, '?').join(',');
      final rows = await db.rawQuery(
        '''
        SELECT
          pr.id,
          pr.patientId,
          pr.recordDate,
          pr.doctorId,
          d.name AS doctorName,
          COUNT(pi.id) AS itemCount
        FROM prescriptions pr
        LEFT JOIN doctors d ON d.id = pr.doctorId
        LEFT JOIN prescription_items pi
          ON pi.prescriptionId = pr.id
         AND ifnull(pi.isDeleted,0)=0
        WHERE pr.patientId IN ($placeholders)
          AND ifnull(pr.isDeleted,0)=0
        GROUP BY pr.id, pr.patientId, pr.recordDate, pr.doctorId, d.name
        ORDER BY pr.recordDate DESC, pr.id DESC
        ''',
        visitIds,
      );

      int asInt(dynamic value) {
        if (value is num) return value.toInt();
        return int.tryParse(value?.toString() ?? '') ?? 0;
      }

      prescriptions.addAll(
        rows.map(
          (row) => _PrescriptionHistoryEntry(
            id: asInt(row['id']),
            patientId: asInt(row['patientId']),
            recordDate: DateTime.tryParse(row['recordDate']?.toString() ?? '') ??
                DateTime.now(),
            doctorName: row['doctorName']?.toString(),
            itemCount: asInt(row['itemCount']),
          ),
        ),
      );
    }

    final returns = (await DBService.instance.getAllReturns())
        .where(_matchesReturnEntry)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return _PatientHistoryBundle(
      visits: visits,
      servicesByPatientId: servicesByPatientId,
      prescriptions: prescriptions,
      returns: returns,
    );
  }

  Future<_PatientReportsBundle> _loadPatientReports() async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId;
    if (accountId == null || accountId.isEmpty) {
      return const _PatientReportsBundle(
        message: 'لا يوجد حساب مرتبط حاليًا.',
      );
    }

    final remotePatientId = await _questionsService.resolveRemotePatientId(
      patient: _patient,
      accountId: accountId,
    );
    if (remotePatientId == null || remotePatientId.isEmpty) {
      return const _PatientReportsBundle(
        message: 'المريض غير مزامن على الخادم بعد.',
      );
    }

    final reports = await _questionsService.fetchReports(patientId: remotePatientId);
    return _PatientReportsBundle(
      remotePatientId: remotePatientId,
      reports: reports,
    );
  }

  Future<String?> _resolveRemotePatientId() async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId;
    if (accountId == null || accountId.isEmpty) return null;
    return _questionsService.resolveRemotePatientId(
      patient: _patient,
      accountId: accountId,
    );
  }

  Future<void> _openNewPrescription() async {
    if (_launchingClinicalAction) return;
    setState(() => _launchingClinicalAction = true);
    try {
      final prescriptionId = await Navigator.push<int>(
        context,
        MaterialPageRoute(
          builder: (_) => NewPrescriptionScreen(patient: _patient),
        ),
      );
      if (!mounted) return;
      if (prescriptionId != null) {
        final savedPrescriptionId = prescriptionId;
        setState(() {
          _selectedRecordTab = _PatientRecordTab.prescriptions;
          _highlightPrescriptionId = savedPrescriptionId;
        });
        _refreshClinicalSections(refreshReports: false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const LocalizedText('تم حفظ الوصفة الطبية.'),
            action: SnackBarAction(
              label: 'استعراض',
              onPressed: () => _openPrescription(savedPrescriptionId),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _launchingClinicalAction = false);
    }
  }

  Future<void> _openNewReturn() async {
    if (_launchingClinicalAction) return;
    setState(() => _launchingClinicalAction = true);
    try {
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => NewReturnScreen(
            patient: _patient,
            returnToListOnSave: false,
          ),
        ),
      );
      if (!mounted) return;
      if (saved == true) {
        setState(() => _selectedRecordTab = _PatientRecordTab.returns);
        _refreshClinicalSections(refreshReports: false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LocalizedText('تم إنشاء العودة بنجاح.')),
        );
      }
    } finally {
      if (mounted) setState(() => _launchingClinicalAction = false);
    }
  }

  Future<void> _openReportEditor() async {
    if (_launchingClinicalAction) return;
    setState(() => _launchingClinicalAction = true);
    try {
      final auth = context.read<AuthProvider>();
      final accountId = auth.accountId;
      if (accountId == null || accountId.isEmpty) return;

      final remotePatientId = await _resolveRemotePatientId();
      if (!mounted) return;
      if (remotePatientId == null || remotePatientId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText('المريض غير مزامن على الخادم بعد.'),
          ),
        );
        return;
      }

      final complaints = await _questionsService.fetchPatientComplaints(
        patientId: remotePatientId,
      );
      if (!mounted) return;
      if (complaints.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText('احفظ الشكوى وإجاباتها أولًا قبل إنشاء التقرير.'),
          ),
        );
        return;
      }

      final templates = await _questionsService.fetchTemplates(
        accountId: accountId,
        includeInactive: true,
      );
      final templateMap = {for (final t in templates) t.id: t.title};

      PatientComplaint selectedComplaint = complaints.first;
      if (complaints.length > 1 && mounted) {
        final picked = await showDialog<PatientComplaint>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const LocalizedText('اختر الشكوى'),
            children: complaints
                .map(
                  (complaint) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, complaint),
                    child: Text(
                      complaint.complaintTitleCustom ??
                          templateMap[complaint.complaintId] ??
                          'شكوى غير معنونة',
                    ),
                  ),
                )
                .toList(),
          ),
        );
        if (picked != null) {
          selectedComplaint = picked;
        }
      }

      if (!mounted) return;
      final createdReportId = await Navigator.push<String?>(
        context,
        MaterialPageRoute(
          builder: (_) => ReportEditorScreen(
            patient: _patient,
            remotePatientId: remotePatientId,
            complaint: selectedComplaint,
          ),
        ),
      );

      if (!mounted) return;
      if (createdReportId != null && createdReportId.trim().isNotEmpty) {
        final savedReportId = createdReportId;
        setState(() => _selectedRecordTab = _PatientRecordTab.reports);
        _refreshClinicalSections();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const LocalizedText('تم حفظ التقرير الطبي.'),
            action: SnackBarAction(
              label: 'استعراض',
              onPressed: () => _openReportById(savedReportId),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذر فتح محرر التقرير: $e')),
      );
    } finally {
      if (mounted) setState(() => _launchingClinicalAction = false);
    }
  }

  Future<void> _openReportById(String reportId) async {
    try {
      final report = await _questionsService.fetchReportById(reportId);
      if (!mounted) return;
      if (report == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LocalizedText('تعذر العثور على التقرير.')),
        );
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReportViewScreen(
            patient: _patient,
            report: report,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذر فتح التقرير: $e')),
      );
    }
  }

  Future<void> _openReportsList() async {
    if (_launchingClinicalAction) return;
    setState(() => _launchingClinicalAction = true);
    try {
      final remotePatientId = await _resolveRemotePatientId();
      if (!mounted) return;
      if (remotePatientId == null || remotePatientId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LocalizedText('المريض غير مزامن على الخادم بعد.'),
          ),
        );
        return;
      }

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PatientReportsListScreen(
            patient: _patient,
            remotePatientId: remotePatientId,
          ),
        ),
      );
      if (mounted) {
        _refreshClinicalSections();
      }
    } finally {
      if (mounted) setState(() => _launchingClinicalAction = false);
    }
  }

  Future<void> _openPrescription(int prescriptionId) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViewPrescriptionScreen(prescriptionId: prescriptionId),
      ),
    );
  }

  Future<_PrescriptionPdfPayload> _loadPrescriptionPdfPayload(
    int prescriptionId,
  ) async {
    final db = await DBService.instance.database;
    final head = await db.query(
      'prescriptions',
      where: 'id = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [prescriptionId],
      limit: 1,
    );
    if (head.isEmpty) {
      throw StateError('Prescription not found');
    }

    final prescription = Prescription.fromMap(head.first);
    final patientRows = await db.query(
      'patients',
      where: 'id = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [prescription.patientId],
      limit: 1,
    );
    if (patientRows.isEmpty) {
      throw StateError('Patient not found');
    }
    final patient = Patient.fromMap(Map<String, dynamic>.from(patientRows.first));

    Doctor? doctor;
    if (prescription.doctorId != null) {
      final doctorRows = await db.query(
        'doctors',
        where: 'id = ? AND ifnull(isDeleted,0)=0',
        whereArgs: [prescription.doctorId],
        limit: 1,
      );
      if (doctorRows.isNotEmpty) {
        doctor = Doctor.fromMap(Map<String, dynamic>.from(doctorRows.first));
      }
    }

    final itemRows = await db.query(
      'prescription_items',
      where: 'prescriptionId = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [prescription.id],
      orderBy: 'id ASC',
    );

    final items = <Map<String, dynamic>>[];
    for (final row in itemRows) {
      final drugId = (row['drugId'] is num)
          ? (row['drugId'] as num).toInt()
          : int.tryParse('${row['drugId'] ?? 0}') ?? 0;
      final drugRows = await db.query(
        'drugs',
        where: 'id = ?',
        whereArgs: [drugId],
        limit: 1,
      );
      if (drugRows.isEmpty) continue;
      items.add({
        'drug': Drug.fromMap(Map<String, dynamic>.from(drugRows.first)),
        'days': (row['days'] is num)
            ? (row['days'] as num).toInt()
            : int.tryParse('${row['days'] ?? 0}') ?? 0,
        'times': (row['timesPerDay'] is num)
            ? (row['timesPerDay'] as num).toInt()
            : int.tryParse('${row['timesPerDay'] ?? 0}') ?? 0,
      });
    }

    return _PrescriptionPdfPayload(
      patient: patient,
      doctor: doctor,
      items: items,
      recordDate: prescription.recordDate,
    );
  }

  Future<void> _sharePrescriptionPdf(int prescriptionId) async {
    try {
      final data = await _loadPrescriptionPdfPayload(prescriptionId);
      await PrescriptionPdfService.sharePdf(
        patient: data.patient,
        doctor: data.doctor,
        items: data.items,
        recordDate: data.recordDate,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذّر تصدير الوصفة: $e')),
      );
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

  String _formatTimelineDateTime(DateTime dt) {
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
          SnackBar(content: LocalizedText('الملف غير موجود: ${a.fileName}')),
        );
        return;
      }
      await OpenFile.open(a.filePath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذر فتح الملف: $e')),
      );
    }
  }

  Widget _buildClinicalActionsSection(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final canCreatePrescription = auth.isSuperAdmin ||
        (auth.featureAllowed(FeatureKeys.prescriptions) && auth.canCreate);
    final canCreateReturn = auth.isSuperAdmin ||
        (auth.featureAllowed(FeatureKeys.returns) && auth.canCreate);
    final canUsePatientQuestions = auth.isSuperAdmin ||
        (_isDoctorUser && auth.featureAllowed(FeatureKeys.patientQuestions));

    final actions = <_ClinicalActionCardData>[
      if (canCreatePrescription)
        _ClinicalActionCardData(
          title: 'إنشاء وصفة طبية',
          subtitle: 'تعبئة المريض والطبيب تلقائيًا',
          icon: Icons.medication_outlined,
          onTap: _openNewPrescription,
        ),
      if (canUsePatientQuestions)
        _ClinicalActionCardData(
          title: 'إنشاء تقرير',
          subtitle: 'من الشكاوى والإجابات المحفوظة',
          icon: Icons.description_outlined,
          onTap: _openReportEditor,
        ),
      if (canUsePatientQuestions)
        _ClinicalActionCardData(
          title: 'تقارير المريض',
          subtitle: 'استعراض وطباعة التقارير السابقة',
          icon: Icons.folder_shared_outlined,
          onTap: _openReportsList,
        ),
      if (canCreateReturn)
        _ClinicalActionCardData(
          title: 'إنشاء عودة',
          subtitle: 'فتح نموذج العودة لهذا المريض',
          icon: Icons.assignment_return_outlined,
          onTap: _openNewReturn,
        ),
    ];

    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    final crossAxisCount = MediaQuery.of(context).size.width >= 960 ? 4 : 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(title: 'إجراءات الطبيب', color: kPrimaryColor),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: actions.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: crossAxisCount == 4 ? 1.28 : 1.1,
          ),
          itemBuilder: (_, index) => _PatientActionCard(
            data: actions[index],
            enabled: !_launchingClinicalAction,
          ),
        ),
      ],
    );
  }

  Widget _buildMedicalHistorySection(BuildContext context) {
    final tabs = const <_PatientRecordTabData>[
      _PatientRecordTabData(
        tab: _PatientRecordTab.visits,
        label: 'الزيارات',
        icon: Icons.history,
      ),
      _PatientRecordTabData(
        tab: _PatientRecordTab.prescriptions,
        label: 'الوصفات',
        icon: Icons.menu_book_outlined,
      ),
      _PatientRecordTabData(
        tab: _PatientRecordTab.reports,
        label: 'التقارير',
        icon: Icons.assignment_outlined,
      ),
      _PatientRecordTabData(
        tab: _PatientRecordTab.returns,
        label: 'العودات',
        icon: Icons.assignment_return_outlined,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(title: 'السجل الطبي', color: kPrimaryColor),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: tabs
              .map(
                (tab) => ChoiceChip(
                  selected: _selectedRecordTab == tab.tab,
                  onSelected: (_) =>
                      setState(() => _selectedRecordTab = tab.tab),
                  label: LocalizedText(tab.label),
                  avatar: Icon(
                    tab.icon,
                    size: 18,
                    color: _selectedRecordTab == tab.tab
                        ? Colors.white
                        : kPrimaryColor,
                  ),
                  selectedColor: kPrimaryColor,
                  labelStyle: TextStyle(
                    color: _selectedRecordTab == tab.tab
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                  side: BorderSide(
                    color: kPrimaryColor.withValues(alpha: .25),
                  ),
                  backgroundColor: Theme.of(context).colorScheme.surface,
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: KeyedSubtree(
            key: ValueKey(_selectedRecordTab),
            child: _buildSelectedRecordTab(context),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedRecordTab(BuildContext context) {
    switch (_selectedRecordTab) {
      case _PatientRecordTab.visits:
      case _PatientRecordTab.prescriptions:
      case _PatientRecordTab.returns:
        return FutureBuilder<_PatientHistoryBundle>(
          future: _patientHistoryFuture,
          builder: (_, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return _buildHistoryLoadingCard();
            }
            if (snapshot.hasError) {
              return _buildHistoryErrorCard(
                'تعذر تحميل السجل الطبي: ${snapshot.error}',
                onRetry: () => _refreshClinicalSections(refreshReports: false),
              );
            }
            final bundle = snapshot.data ??
                const _PatientHistoryBundle(
                  visits: <Patient>[],
                  servicesByPatientId: <int, List<PatientService>>{},
                  prescriptions: <_PrescriptionHistoryEntry>[],
                  returns: <ReturnEntry>[],
                );
            switch (_selectedRecordTab) {
              case _PatientRecordTab.visits:
                return _buildVisitsTab(bundle);
              case _PatientRecordTab.prescriptions:
                return _buildPrescriptionsTab(bundle, context);
              case _PatientRecordTab.returns:
                return _buildReturnsTab(bundle);
              case _PatientRecordTab.reports:
                return const SizedBox.shrink();
            }
          },
        );
      case _PatientRecordTab.reports:
        return FutureBuilder<_PatientReportsBundle>(
          future: _patientReportsFuture,
          builder: (_, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return _buildHistoryLoadingCard();
            }
            if (snapshot.hasError) {
              return _buildHistoryErrorCard(
                'تعذر تحميل التقارير: ${snapshot.error}',
                onRetry: () => _refreshClinicalSections(),
              );
            }
            final bundle = snapshot.data ?? const _PatientReportsBundle();
            return _buildReportsTab(bundle, context);
          },
        );
    }
  }

  Widget _buildHistoryLoadingCard() {
    return const NeuCard(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LocalizedText('جارِ تحميل بيانات السجل...'),
          SizedBox(height: 10),
          LinearProgressIndicator(),
        ],
      ),
    );
  }

  Widget _buildHistoryErrorCard(
    String message, {
    VoidCallback? onRetry,
  }) {
    return NeuCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LocalizedText(message),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const LocalizedText('إعادة المحاولة'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVisitsTab(_PatientHistoryBundle bundle) {
    if (bundle.visits.isEmpty) {
      return const NeuCard(
        padding: EdgeInsets.all(16),
        child: LocalizedText('لا توجد زيارات محفوظة لهذا المريض.'),
      );
    }

    return Column(
      children: bundle.visits.map((visit) {
        final isCurrent = visit.id == _patient.id;
        final services = visit.id != null
            ? (bundle.servicesByPatientId[visit.id!] ?? const <PatientService>[])
            : const <PatientService>[];
        final totalServices = services.isNotEmpty
            ? services.fold<double>(0, (sum, item) => sum + item.serviceCost)
            : visit.paidAmount + visit.remaining;
        final serviceLabels = services.isNotEmpty
            ? services
                .map((service) =>
                    '${service.serviceName} • ${service.serviceCost.toStringAsFixed(2)}')
                .toList()
            : <String>[
                if ((visit.serviceName ?? '').trim().isNotEmpty)
                  visit.serviceName!.trim()
                else if ((visit.serviceType ?? '').trim().isNotEmpty)
                  _serviceTypePretty(visit.serviceType),
              ];

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NeuCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _formatTimelineDateTime(visit.registerDate),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          LocalizedText(
                            (visit.doctorName ?? '').trim().isEmpty
                                ? 'بدون طبيب محدد'
                                : 'الطبيب: ${visit.doctorName!.trim()}',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: .7),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _HistoryBadge(
                      label: isCurrent ? 'السجل الحالي' : 'زيارة سابقة',
                      color: isCurrent ? kPrimaryColor : Colors.teal,
                    ),
                  ],
                ),
                if (visit.diagnosis.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  LocalizedText(
                    'التشخيص: ${visit.diagnosis.trim()}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
                if (serviceLabels.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: serviceLabels
                        .map(
                          (label) => Chip(
                            backgroundColor: kPrimaryColor.withValues(alpha: .08),
                            label: Text(label),
                          ),
                        )
                        .toList(),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _HistoryStatChip(
                      icon: Icons.payments_outlined,
                      label: 'المدفوع',
                      value: visit.paidAmount.toStringAsFixed(2),
                    ),
                    _HistoryStatChip(
                      icon: Icons.money_off_outlined,
                      label: 'المتبقي',
                      value: visit.remaining.toStringAsFixed(2),
                    ),
                    _HistoryStatChip(
                      icon: Icons.summarize_outlined,
                      label: 'إجمالي الخدمات',
                      value: totalServices.toStringAsFixed(2),
                    ),
                  ],
                ),
                if (!isCurrent && visit.id != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TOutlinedButton(
                      icon: Icons.open_in_new,
                      label: 'استعراض السجل',
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ViewPatientScreen(patient: visit),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPrescriptionsTab(
    _PatientHistoryBundle bundle,
    BuildContext context,
  ) {
    if (bundle.prescriptions.isEmpty) {
      return NeuCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LocalizedText('لا توجد وصفات طبية محفوظة لهذا المريض بعد.'),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _openNewPrescription,
              icon: const Icon(Icons.add),
              label: const LocalizedText('إنشاء وصفة'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: bundle.prescriptions.map((entry) {
        final highlighted = entry.id == _highlightPrescriptionId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: highlighted
                  ? Border.all(color: kPrimaryColor, width: 1.4)
                  : null,
            ),
            child: NeuCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'وصفة ${_formatTimelineDateTime(entry.recordDate)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 4),
                            LocalizedText(
                              (entry.doctorName ?? '').trim().isEmpty
                                  ? 'بدون طبيب محدد'
                                  : 'الطبيب: ${entry.doctorName!.trim()}',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: .7),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _HistoryBadge(
                        label: '${entry.itemCount} دواء',
                        color: highlighted ? kPrimaryColor : Colors.indigo,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TOutlinedButton(
                        icon: Icons.visibility_outlined,
                        label: 'استعراض',
                        onPressed: () => _openPrescription(entry.id),
                      ),
                      TOutlinedButton(
                        icon: Icons.picture_as_pdf_outlined,
                        label: 'PDF',
                        onPressed: () => _sharePrescriptionPdf(entry.id),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildReportsTab(
    _PatientReportsBundle bundle,
    BuildContext context,
  ) {
    if (!bundle.isSynced) {
      return NeuCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LocalizedText(bundle.message ?? 'المريض غير مزامن على الخادم بعد.'),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => _refreshClinicalSections(),
              icon: const Icon(Icons.refresh),
              label: const LocalizedText('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }

    if (bundle.reports.isEmpty) {
      return NeuCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LocalizedText('لا توجد تقارير محفوظة لهذا المريض بعد.'),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _openReportEditor,
              icon: const Icon(Icons.add),
              label: const LocalizedText('إنشاء تقرير'),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _openReportsList,
            icon: const Icon(Icons.list_alt),
            label: const LocalizedText('عرض قائمة التقارير كاملة'),
          ),
        ),
        ...bundle.reports.map((report) {
          final complaint = (report.snapshot['complaint'] as Map?) ?? const {};
          final title = (complaint['title'] ?? '').toString().trim();
          final date = report.createdAt != null
              ? _formatTimelineDateTime(report.createdAt!)
              : '—';
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: NeuCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? 'تقرير طبي' : 'تقرير: $title',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  LocalizedText(
                    'التاريخ: $date',
                    style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: .7),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TOutlinedButton(
                        icon: Icons.visibility_outlined,
                        label: 'استعراض',
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReportViewScreen(
                              patient: _patient,
                              report: report,
                            ),
                          ),
                        ),
                      ),
                      TOutlinedButton(
                        icon: Icons.picture_as_pdf_outlined,
                        label: 'PDF',
                        onPressed: () => PatientReportPdfService.sharePdf(
                          patient: _patient,
                          report: report,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildReturnsTab(_PatientHistoryBundle bundle) {
    if (bundle.returns.isEmpty) {
      return NeuCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LocalizedText('لا توجد عودات مرتبطة بهذا المريض حتى الآن.'),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _openNewReturn,
              icon: const Icon(Icons.add),
              label: const LocalizedText('إنشاء عودة'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: bundle.returns.map((entry) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NeuCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _formatTimelineDateTime(entry.date),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    _HistoryBadge(
                      label: entry.isAttended ? 'تمت المراجعة' : 'بانتظار الموعد',
                      color: entry.isAttended ? Colors.green : Colors.orange,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LocalizedText(
                  entry.doctor.trim().isEmpty
                      ? 'بدون طبيب محدد'
                      : 'الطبيب: ${entry.doctor.trim()}',
                ),
                if (entry.diagnosis.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  LocalizedText('التشخيص: ${entry.diagnosis.trim()}'),
                ],
                if (entry.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  LocalizedText('ملاحظات: ${entry.notes.trim()}'),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _HistoryStatChip(
                      icon: Icons.money_off_outlined,
                      label: 'المتبقي',
                      value: entry.remaining.toStringAsFixed(2),
                    ),
                    _HistoryStatChip(
                      icon: Icons.person_outline,
                      label: 'العمر',
                      value: entry.age.toString(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  /*────────────── أدوات PDF مساعدة ──────────────*/
  /*────────────── مولِّد PDF (Bytes) ──────────────*/
  Future<Uint8List> _buildPatientPdfBytes() async {
    final patient = _patient;
    final i18n = ReportLocalizer();

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

    // الخطوط والشعار
    pw.Font cairoRegular;
    pw.Font cairoBold;
    Uint8List? logo;
    try {
      final fonts = await loadPdfFonts();
      cairoRegular = fonts.regular;
      cairoBold = fonts.bold;
    } catch (_) {
      // احتياط في حال غابت الملفات
      cairoRegular = pw.Font.helvetica();
      cairoBold = pw.Font.helveticaBold();
    }
    try {
      logo = await ClinicProfileService.loadReportLogoBytes();
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

    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final pdf = pw.Document();

    final baseText =
        pw.TextStyle(font: cairoRegular, fontSize: 12, height: 1.35);
    final boldText = pw.TextStyle(font: cairoBold, fontSize: 12, height: 1.35);

    final pageTheme = i18n.pageTheme(base: cairoRegular, bold: cairoBold);

    pw.Widget thinDivider([double v = 6]) => pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: v),
          child: pw.Container(height: 0.7, color: PdfColors.grey300),
        );

    pw.Widget infoRow(String label, String value, {bool isRecordNo = false}) {
      final valueStyle = isRecordNo
          ? pw.TextStyle(
              font: cairoBold, fontSize: 13, color: PdfColors.red, height: 1.4)
          : baseText;
      final labelWidget = pw.Text(
        i18n.pdf(label),
        style: boldText,
        textAlign: i18n.startAlign,
      );
      final valueWidget = pw.Expanded(
        child: pw.Text(
          pdfText(value),
          style: valueStyle,
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

    List<List<List<String>>> chunkRows(
        List<List<String>> rows, int size) {
      if (rows.isEmpty) return const [];
      final chunks = <List<List<String>>>[];
      for (var i = 0; i < rows.length; i += size) {
        chunks.add(rows.sublist(i, math.min(i + size, rows.length)));
      }
      return chunks;
    }

    List<pw.Widget> buildServiceTables() {
      final tables = <pw.Widget>[];
      const maxRowsPerTable = 18;
      final chunks = chunkRows(serviceRows, maxRowsPerTable);
      if (chunks.isEmpty) {
        tables.add(
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
                    child: pw.Text(i18n.pdf('السعر'),
                        style: boldText, textAlign: pw.TextAlign.center),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(i18n.pdf('الخدمة'),
                        style: boldText, textAlign: i18n.startAlign),
                  ),
                ],
              ),
              pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text('—',
                        style: baseText, textAlign: pw.TextAlign.center),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(i18n.pdf('لا توجد خدمات مسجلة'),
                        style: baseText, textAlign: i18n.startAlign),
                  ),
                ],
              ),
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(
                      i18n.formatNumber(totalCost),
                      style: pw.TextStyle(
                          font: cairoBold,
                          fontSize: 12,
                          color: PdfColors.green700),
                      textAlign: pw.TextAlign.center,
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(i18n.pdf('الإجمالي'),
                        style: pw.TextStyle(
                            font: cairoBold,
                            fontSize: 12,
                            color: PdfColors.green700),
                        textAlign: i18n.startAlign),
                  ),
                ],
              ),
            ],
          ),
        );
        return tables;
      }

      for (var idx = 0; idx < chunks.length; idx++) {
        final part = chunks[idx];
        tables.add(
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
                    child: pw.Text(i18n.pdf('السعر'),
                        style: boldText, textAlign: pw.TextAlign.center),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(i18n.pdf('الخدمة'),
                        style: boldText, textAlign: i18n.startAlign),
                  ),
                ],
              ),
              for (final r in part)
                pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(8),
                      child: pw.Text(
                        i18n.formatNumber(double.tryParse(r[0]) ?? 0),
                        style: baseText,
                        textAlign: pw.TextAlign.center,
                      ),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(8),
                      child: pw.Text(
                        pdfText(r[1]),
                        style: baseText,
                        textAlign: i18n.startAlign,
                      ),
                    ),
                  ],
                ),
              if (idx == chunks.length - 1)
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                  children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(
                      i18n.formatNumber(totalCost),
                      style: pw.TextStyle(
                          font: cairoBold,
                          fontSize: 12,
                          color: PdfColors.green700),
                      textAlign: pw.TextAlign.center,
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(i18n.pdf('الإجمالي'),
                        style: pw.TextStyle(
                            font: cairoBold,
                            fontSize: 12,
                            color: PdfColors.green700),
                        textAlign: i18n.startAlign),
                  ),
                ],
              ),
            ],
          ),
        );
        if (idx != chunks.length - 1) {
          tables.add(pw.SizedBox(height: 10));
        }
      }

      return tables;
    }

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        header: (_) => i18n.buildLetterhead(
          clinic: clinic,
          regular: cairoRegular,
          bold: cairoBold,
          logoData: logo,
        ),
        footer: (ctx) => i18n.buildFooter(
          clinic: clinic,
          regular: cairoRegular,
          pageNumber: ctx.pageNumber,
          pagesCount: ctx.pagesCount,
        ),
        build: (_) => [
          pw.SizedBox(height: 10),

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
                  i18n.pdf('تفاصيل المريض'),
                  style: pw.TextStyle(
                      font: cairoBold, fontSize: 15, letterSpacing: 1.1),
                ),
              ),
              pw.Expanded(
                  child: pw.Container(height: 0.8, color: PdfColors.grey300)),
            ],
          ),
          pw.SizedBox(height: 10),

          infoRow('رقم السجل', i18n.formatNumber(docCounter, decimalDigits: 0),
              isRecordNo: true),
          thinDivider(),
          infoRow('تاريخ ووقت التسجيل', _formatRegistrationDateTime()),
          thinDivider(),
          infoRow('اسم المريض', patient.name),
          thinDivider(),
          infoRow('العمر', i18n.formatNumber(patient.age, decimalDigits: 0)),
          thinDivider(),
          infoRow('رقم الهاتف',
              patient.phoneNumber.isEmpty ? '—' : patient.phoneNumber),
          if (displayDoctorName != '---') ...[
            thinDivider(),
            infoRow('اسم الطبيب', displayDoctorName),
          ],
          if (patient.doctorShare > 0) ...[
            thinDivider(),
            infoRow(
              'حصة الطبيب (الأشعة/المختبر)',
              i18n.formatNumber(patient.doctorShare),
            ),
          ],

          pw.SizedBox(height: 18),

          pw.Row(
            children: [
              pw.Expanded(
                  child: pw.Container(height: 0.6, color: PdfColors.grey300)),
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8),
                child: pw.Text(i18n.pdf('الخدمات'),
                    style: pw.TextStyle(font: cairoBold, fontSize: 14)),
              ),
              pw.Expanded(
                  child: pw.Container(height: 0.6, color: PdfColors.grey300)),
            ],
          ),
          pw.SizedBox(height: 6),

          ...buildServiceTables(),
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
      final i18n = ReportLocalizer();
      await Printing.sharePdf(
        bytes: bytes,
        filename: i18n.fileName(
          'سجل المريض',
          extension: 'pdf',
          suffixes: <Object?>[_patient.id],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('حدث خطأ أثناء إنشاء PDF: $e')),
      );
    }
  }

  Future<void> _printPdf() async {
    try {
      await Printing.layoutPdf(onLayout: (_) async => _buildPatientPdfBytes());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذّرت الطباعة: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currentPatient = _patient;
    final hasDoctor = (currentPatient.doctorName?.trim().isNotEmpty ?? false);
    final hasId = currentPatient.id != null;

    return Directionality(
      textDirection: Directionality.of(context),
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
              tooltip: context.trRaw('تصدير PDF'),
              icon: const Icon(Icons.picture_as_pdf),
              onPressed: hasId ? _exportToPdf : null,
            ),
            IconButton(
              tooltip: context.trRaw('طباعة'),
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
                      label: const LocalizedText('تم مقابلة المريض'),
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
                          value: currentPatient.name),
                      const Divider(height: 12),
                      _InfoTile(
                          icon: Icons.cake,
                          label: 'العمر',
                          value: currentPatient.age.toString()),
                      const Divider(height: 12),
                      _InfoTile(
                          icon: Icons.phone,
                          label: 'رقم الهاتف',
                          value: currentPatient.phoneNumber.isEmpty
                              ? '—'
                              : currentPatient.phoneNumber),
                      if (hasDoctor) ...[
                        const Divider(height: 12),
                        _InfoTile(
                            icon: Icons.local_hospital,
                            label: 'الطبيب',
                            value: currentPatient.doctorName!.trim()),
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
                            final fallbackTotal = (_patient.paidAmount +
                                    _patient.remaining)
                                .toStringAsFixed(2);
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const LocalizedText('لا توجد خدمات مسجلة (قد تكون أتت من المزامنة بدون تفاصيل).'),
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
                        value: _patient.paidAmount.toStringAsFixed(2),
                      ),
                      const Divider(height: 12),
                      _InfoTile(
                        icon: Icons.money_off,
                        label: 'المبلغ المتبقي',
                        value: _patient.remaining.toStringAsFixed(2),
                      ),
                      if ((_patient.collateral ?? '').trim().isNotEmpty) ...[
                        const Divider(height: 12),
                        _InfoTile(
                          icon: Icons.verified_outlined,
                          label: 'الرهن',
                          value: _patient.collateral!.trim(),
                          maxLines: 3,
                        ),
                      ],
                      const Divider(height: 12),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TOutlinedButton(
                          icon: Icons.payments_outlined,
                          label: 'تسديد مبلغ',
                          onPressed: _showPaymentDialog,
                        ),
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
                    value: (currentPatient.notes?.trim().isEmpty ?? true)
                        ? '—'
                        : currentPatient.notes!.trim(),
                    maxLines: 4,
                  ),
                ),
                const SizedBox(height: 14),
                if (hasId) ...[
                  _buildClinicalActionsSection(context),
                  const SizedBox(height: 14),
                  _buildMedicalHistorySection(context),
                  const SizedBox(height: 14),
                ],
                PatientDetailsQuestionsSection(patient: currentPatient),
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
                        return const LocalizedText('لا توجد مرفقات');
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
                        label: const LocalizedText('تصدير PDF'),
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
                        label: const LocalizedText('طباعة'),
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
                  child: const LocalizedText('رجوع'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _PatientRecordTab { visits, prescriptions, reports, returns }

class _PatientRecordTabData {
  final _PatientRecordTab tab;
  final String label;
  final IconData icon;

  const _PatientRecordTabData({
    required this.tab,
    required this.label,
    required this.icon,
  });
}

class _ClinicalActionCardData {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _ClinicalActionCardData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });
}

class _PatientHistoryBundle {
  final List<Patient> visits;
  final Map<int, List<PatientService>> servicesByPatientId;
  final List<_PrescriptionHistoryEntry> prescriptions;
  final List<ReturnEntry> returns;

  const _PatientHistoryBundle({
    required this.visits,
    required this.servicesByPatientId,
    required this.prescriptions,
    required this.returns,
  });
}

class _PrescriptionHistoryEntry {
  final int id;
  final int patientId;
  final DateTime recordDate;
  final String? doctorName;
  final int itemCount;

  const _PrescriptionHistoryEntry({
    required this.id,
    required this.patientId,
    required this.recordDate,
    required this.doctorName,
    required this.itemCount,
  });
}

class _PatientReportsBundle {
  final String? remotePatientId;
  final List<PatientReport> reports;
  final String? message;

  const _PatientReportsBundle({
    this.remotePatientId,
    this.reports = const <PatientReport>[],
    this.message,
  });

  bool get isSynced =>
      remotePatientId != null && remotePatientId!.trim().isNotEmpty;
}

class _PrescriptionPdfPayload {
  final Patient patient;
  final Doctor? doctor;
  final List<Map<String, dynamic>> items;
  final DateTime recordDate;

  const _PrescriptionPdfPayload({
    required this.patient,
    required this.doctor,
    required this.items,
    required this.recordDate,
  });
}

class _PatientActionCard extends StatelessWidget {
  final _ClinicalActionCardData data;
  final bool enabled;

  const _PatientActionCard({
    required this.data,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : .65,
      child: NeuCard(
        onTap: enabled ? data.onTap : null,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(10),
              child: Icon(data.icon, color: kPrimaryColor, size: 22),
            ),
            const SizedBox(height: 12),
            LocalizedText(
              data.title,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14.5,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: LocalizedText(
                data.subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .7),
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _HistoryBadge({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: LocalizedText(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _HistoryStatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _HistoryStatChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: kPrimaryColor),
          const SizedBox(width: 6),
          LocalizedText(
            '$label: $value',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ],
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
        child: LocalizedText(
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
      title: LocalizedText(
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
