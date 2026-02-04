// ── lib/screens/patients/list_patients_screen.dart ─────────────────────────────

import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:aelmamclinic/screens/patients/new_patient_screen.dart';
import 'package:aelmamclinic/screens/patients/edit_patient_screen.dart';
import 'package:aelmamclinic/screens/patients/view_patient_screen.dart';
import 'package:aelmamclinic/screens/patients/duplicate_patients_screen.dart';
import 'package:aelmamclinic/screens/patient_questions/report_editor_screen.dart';
import 'package:aelmamclinic/screens/patient_questions/patient_reports_list_screen.dart';

import 'package:aelmamclinic/core/formatters.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/core/features.dart';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_service.dart';
import 'package:aelmamclinic/models/patient_complaint.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/export_service.dart';
import 'package:aelmamclinic/services/save_file_service.dart';
import 'package:aelmamclinic/services/patient_questions_service.dart';

class ListPatientsScreen extends StatefulWidget {
  const ListPatientsScreen({super.key});

  @override
  State<ListPatientsScreen> createState() => _ListPatientsScreenState();
}

class _ListPatientsScreenState extends State<ListPatientsScreen> {
  List<Patient> _patients = [];
  List<Patient> _filteredPatients = [];
  final TextEditingController _searchController = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;

  final Map<int, List<PatientService>> _servicesByPatient = {};
  final PatientQuestionsService _questionsService = PatientQuestionsService();
  final Map<int, String> _remotePatientIds = {};
  final Map<int, int> _reportCounts = {};
  bool _reportCountsLoading = false;

  bool _isLoading = false;
  Timer? _debounce;
  int? _activeDoctorId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveDoctorAndLoad();
    });
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _filterPatients);
  }

  Future<void> _resolveDoctorAndLoad() async {
    setState(() => _isLoading = true);
    try {
      final auth = context.read<AuthProvider>();
      final uid = auth.uid;
      int? doctorId;
      if (uid != null && uid.isNotEmpty) {
        final doctor = await DBService.instance.getDoctorByUserUid(uid);
        doctorId = doctor?.id;
      }
      if (!mounted) return;
      _activeDoctorId = doctorId;
      await _loadPatients(showSpinner: false);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadPatients({bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() => _isLoading = true);
    }
    try {
      final patients =
          await DBService.instance.getAllPatients(doctorId: _activeDoctorId);
      final db = await DBService.instance.database;

      final ids =
          patients.where((p) => p.id != null).map((p) => p.id!).toList();
      final svcMap = <int, List<PatientService>>{};

      if (ids.isNotEmpty) {
        final placeholders = List.filled(ids.length, '?').join(',');
        final rows = await db.rawQuery(
          'SELECT * FROM ${PatientService.table} WHERE patientId IN ($placeholders)',
          ids,
        );
        for (final r in rows) {
          final pid = (r['patientId'] as num).toInt();
          svcMap.putIfAbsent(pid, () => []).add(
                PatientService(
                  id: (r['id'] as num?)?.toInt(),
                  patientId: pid,
                  serviceId: (r['serviceId'] as num?)?.toInt(),
                  serviceName: (r['serviceName'] as String?) ?? '',
                  serviceCost: (r['serviceCost'] as num).toDouble(),
                ),
              );
        }
      }

      setState(() {
        _patients = patients;
        _filteredPatients = patients;
        _servicesByPatient
          ..clear()
          ..addAll(svcMap);
      });
      _filterPatients();
      unawaited(_loadReportCounts(patients));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل تحميل البيانات: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadReportCounts(List<Patient> patients) async {
    if (_reportCountsLoading) return;
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId;
    if (accountId == null || accountId.isEmpty) return;
    setState(() => _reportCountsLoading = true);
    try {
      final mapping = await _questionsService.mapLocalPatientsToRemote(
        patients: patients,
        accountId: accountId,
      );
      final remoteIds = mapping.values.toList();
      final counts = await _questionsService.countReportsByPatientIds(remoteIds);
      final localCounts = <int, int>{};
      for (final entry in mapping.entries) {
        localCounts[entry.key] = counts[entry.value] ?? 0;
      }
      if (!mounted) return;
      setState(() {
        _remotePatientIds
          ..clear()
          ..addAll(mapping);
        _reportCounts
          ..clear()
          ..addAll(localCounts);
      });
    } catch (_) {
      if (!mounted) return;
    } finally {
      if (mounted) setState(() => _reportCountsLoading = false);
    }
  }

  Future<void> _openReportEditor(Patient p) async {
    final auth = context.read<AuthProvider>();
    final accountId = auth.accountId;
    if (accountId == null || accountId.isEmpty) return;
    final localId = p.localId ?? p.id;
    final remoteId = localId != null ? _remotePatientIds[localId] : null;
    if (remoteId == null || remoteId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المريض غير مزامن على الخادم بعد.')),
      );
      return;
    }
    try {
      final complaints =
          await _questionsService.fetchPatientComplaints(patientId: remoteId);
      final templates = await _questionsService.fetchTemplates(
        accountId: accountId,
        includeInactive: true,
      );
      final templateMap = {for (final t in templates) t.id: t.title};
      if (complaints.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد شكاوى مرتبطة بهذا المريض.')),
        );
        return;
      }
      PatientComplaint? selected = complaints.first;
      if (complaints.length > 1 && mounted) {
        final picked = await showDialog<PatientComplaint>(
          context: context,
          builder: (ctx) {
            return SimpleDialog(
              title: const Text('اختر الشكوى'),
              children: complaints
                  .map(
                    (c) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, c),
                      child: Text(
                        c.complaintTitleCustom ??
                            templateMap[c.complaintId] ??
                            'شكوى غير معنونة',
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        );
        if (picked != null) selected = picked;
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReportEditorScreen(
            patient: p,
            remotePatientId: remoteId,
            complaint: selected!,
          ),
        ),
      );
      unawaited(_loadReportCounts(_patients));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر فتح التقرير: $e')),
      );
    }
  }

  Future<void> _openReportsList(Patient p) async {
    final localId = p.localId ?? p.id;
    final remoteId = localId != null ? _remotePatientIds[localId] : null;
    if (remoteId == null || remoteId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المريض غير مزامن على الخادم بعد.')),
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PatientReportsListScreen(
          patient: p,
          remotePatientId: remoteId,
        ),
      ),
    );
  }

  Future<void> _pickStartDate() async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(primary: scheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(
        () => _startDate = DateTime(picked.year, picked.month, picked.day),
      );
      _filterPatients();
    }
  }

  Future<void> _pickEndDate() async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(
            primary: scheme.primary,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(
        () => _endDate = DateTime(picked.year, picked.month, picked.day),
      );
      _filterPatients();
    }
  }

  void _resetDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _filterPatients();
  }

  void _filterPatients() {
    final rawQ = _searchController.text;
    final qNorm = Formatters.normalizeForSearch(rawQ);
    final qPhone = Formatters.normalizePhone(rawQ);

    setState(() {
      _filteredPatients = _patients.where((p) {
        final nameNorm = Formatters.normalizeForSearch(p.name);
        final phoneNorm = Formatters.normalizePhone(p.phoneNumber);

        final nameMatch = nameNorm.contains(qNorm);
        final phoneMatch = qPhone.isEmpty ? false : phoneNorm.contains(qPhone);

        var inRange = true;
        final rd = p.registerDate;
        if (_startDate != null) {
          inRange = rd.isAfter(_startDate!.subtract(const Duration(days: 1)));
        }
        if (_endDate != null && inRange) {
          inRange = rd.isBefore(_endDate!.add(const Duration(days: 1)));
        }
        return (nameMatch || phoneMatch || qNorm.isEmpty) && inRange;
      }).toList();
    });
  }

  Future<void> _deletePatient(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text('هل تريد حذف سجل المريض؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await DBService.instance.deletePatient(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم الحذف بنجاح')),
      );
      await _loadPatients();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر الحذف: $e')),
      );
    }
  }

  Future<void> _shareFile() async {
    if (_filteredPatients.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للمشاركة')),
      );
      return;
    }
    final bytes = await ExportService.exportPatientsToExcel(_filteredPatients);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/كشف-اسماء-المرضى.xlsx');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: 'ملف المرضى المحفوظ',
      ),
    );
  }

  Future<void> _downloadFile() async {
    if (_filteredPatients.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للتنزيل')),
      );
      return;
    }
    final bytes = await ExportService.exportPatientsToExcel(_filteredPatients);
    await saveExcelFile(bytes, 'كشف-اسماء-المرضى.xlsx');
  }

  void _makePhoneCall(String number) async {
    final tel = Formatters.normalizePhone(number);
    final uri = Uri(scheme: 'tel', path: tel);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يمكن إجراء المكالمة')),
      );
    }
  }

  String _summarizeServices(List<PatientService> svcs) {
    if (svcs.isEmpty) return 'لا خدمات';
    final names = svcs
        .map((s) => s.serviceName)
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (names.isEmpty) return 'لا خدمات';
    if (names.length <= 3) return names.join('، ');
    final first3 = names.take(3).join('، ');
    return '$first3 و +${names.length - 3} خدمة';
  }

  String _avatarText(String name) {
    final s = name.trim();
    return s.isEmpty ? '—' : s.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dateFmt = DateFormat('yyyy-MM-dd');
    final auth = context.watch<AuthProvider>();
    final canUseQuestions = auth.isSuperAdmin ||
        auth.isOwnerOrAdmin ||
        auth.featureAllowed(FeatureKeys.patientQuestions);

    // تجميع حسب رقم الهاتف المُطبَّع لاكتشاف المكررات
    final grouped = <String, List<Patient>>{};
    for (final p in _filteredPatients) {
      final phoneKey = Formatters.normalizePhone(p.phoneNumber);
      // السجلات بدون رقم هاتف لا تُعتبر مكررة: نستخدم مفتاحًا فريدًا لها
      final key = phoneKey.isEmpty ? 'id:${p.id ?? p.hashCode}' : phoneKey;
      grouped.putIfAbsent(key, () => []).add(p);
    }
    final groups = grouped.values.toList()
      ..sort(
        (a, b) => b.first.registerDate.compareTo(a.first.registerDate),
      ); // الأحدث أولاً
    final uniqueCount = grouped.length;
    final casesCount = _filteredPatients.length;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('قائمة المرضى'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareFile,
            tooltip: 'مشاركة',
          ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _downloadFile,
            tooltip: 'تنزيل',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const NewPatientScreen(),
            ),
          );
          await _loadPatients();
        },
        icon: const Icon(Icons.add),
        label: const Text('مريض جديد'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: scheme.primary,
          onRefresh: _loadPatients,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              // البحث
              TSearchField(
                controller: _searchController,
                hint: 'ابحث عن اسم المريض أو رقم الهاتف',
                onChanged: (_) => _onSearchChanged(),
                onClear: () {
                  _searchController.clear();
                  _filterPatients();
                },
              ),
              const SizedBox(height: 10),

              // مرشحات التاريخ بنمط TBIAN
              Row(
                children: [
                  Expanded(
                    child: TDateButton(
                      icon: Icons.calendar_month_rounded,
                      label: _startDate == null
                          ? 'من تاريخ'
                          : dateFmt.format(_startDate!),
                      onTap: _pickStartDate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TDateButton(
                      icon: Icons.event_rounded,
                      label: _endDate == null
                          ? 'إلى تاريخ'
                          : dateFmt.format(_endDate!),
                      onTap: _pickEndDate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  TOutlinedButton(
                    icon: Icons.refresh_rounded,
                    label: 'مسح',
                    onPressed: (_startDate == null && _endDate == null)
                        ? null
                        : _resetDates,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // الإحصائيات (NeuCard)
              NeuCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Text(
                      'عدد المرضى: $uniqueCount',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface.withValues(
                          alpha: .9,
                        ),
                      ),
                    ),
                    Text(
                      'عدد الحالات: $casesCount',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface.withValues(
                          alpha: .9,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // قائمة المرضى
              if (_isLoading) ...[
                const SizedBox(height: 120),
                const Center(child: CircularProgressIndicator()),
              ] else if (groups.isEmpty) ...[
                const SizedBox(height: 120),
                const Center(child: Text('لا توجد بيانات')),
              ] else ...[
                ...List.generate(groups.length, (i) {
                  final grp = groups[i];
                  final p = grp[0];

                  final allSvcs = grp
                      .where((pp) => pp.id != null)
                      .expand(
                        (pp) =>
                            _servicesByPatient[pp.id!] ??
                            const <PatientService>[],
                      )
                      .toList();

                  final svcSummary = _summarizeServices(allSvcs);
                  final totalCost =
                      allSvcs.fold<double>(0, (sum, s) => sum + s.serviceCost);
                  final diagnosis = (p.diagnosis).toString().trim().isEmpty
                      ? '—'
                      : p.diagnosis;
                  final needsAttention = p.doctorReviewPending;
                  final pendingLabel =
                      needsAttention ? ' • بانتظار مقابلة الطبيب' : '';
                  final localId = p.localId ?? p.id;
                  final remoteId =
                      localId != null ? _remotePatientIds[localId] : null;
                  final reportCount =
                      localId != null ? (_reportCounts[localId] ?? 0) : 0;
                  final canViewReports =
                      canUseQuestions && remoteId != null && reportCount > 0;
                  final canCreateReport = canUseQuestions && remoteId != null;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: NeuCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Column(
                        children: [
                          ListTile(
                            onTap: () {
                              // إذا مجموعة>1 → شاشة المكرّرات، وإلا شاشة عرض المريض
                              final phoneKey =
                                  Formatters.normalizePhone(p.phoneNumber);
                              if (grp.length > 1 && phoneKey.isNotEmpty) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => DuplicatePatientsScreen(
                                      phoneNumber: phoneKey,
                                      patientName: p.name,
                                    ),
                                  ),
                                ).then((_) => _loadPatients());
                              } else {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ViewPatientScreen(
                                      patient: p,
                                    ),
                                  ),
                                ).then((_) => _loadPatients());
                              }
                            },
                            leading: CircleAvatar(
                              radius: 22,
                              backgroundColor:
                                  kPrimaryColor.withValues(alpha: .10),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Align(
                                    alignment: Alignment.center,
                                    child: Text(
                                      _avatarText(p.name),
                                      style: const TextStyle(
                                        color: kPrimaryColor,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                  if (needsAttention)
                                    Positioned(
                                      top: -2,
                                      left: -2,
                                      child: Container(
                                        width: 14,
                                        height: 14,
                                        decoration: BoxDecoration(
                                          color: Colors.green,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .surface,
                                            width: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            title: Text(
                              p.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Text(
                              '$diagnosis  •  خدمات: $svcSummary  •  الإجمالي: ${totalCost.toStringAsFixed(2)}$pendingLabel',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(
                                      alpha: .75,
                                    ),
                              ),
                            ),
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert),
                              onSelected: (value) async {
                                switch (value) {
                                  case 'call':
                                    if (p.phoneNumber.isNotEmpty) {
                                      _makePhoneCall(p.phoneNumber);
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('لا يوجد رقم هاتف'),
                                        ),
                                      );
                                    }
                                    break;
                                  case 'add':
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => NewPatientScreen(
                                          initialName: p.name,
                                          initialPhone: p.phoneNumber,
                                        ),
                                      ),
                                    );
                                    await _loadPatients();
                                    break;
                                  case 'edit':
                                    if (grp.length == 1) {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => EditPatientScreen(
                                            patient: p,
                                          ),
                                        ),
                                      );
                                      await _loadPatients();
                                    }
                                    break;
                                  case 'delete':
                                    if (p.id != null) {
                                      await _deletePatient(p.id!);
                                    }
                                    break;
                                }
                              },
                              itemBuilder: (ctx) {
                                final items = <PopupMenuEntry<String>>[
                                  const PopupMenuItem(
                                    value: 'call',
                                    child: ListTile(
                                      leading: Icon(Icons.phone),
                                      title: Text('اتصال'),
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'add',
                                    child: ListTile(
                                      leading: Icon(Icons.add),
                                      title: Text('إضافة سجل جديد'),
                                    ),
                                  ),
                                ];
                                if (grp.length == 1) {
                                  items.add(
                                    const PopupMenuItem(
                                      value: 'edit',
                                      child: ListTile(
                                        leading: Icon(Icons.edit),
                                        title: Text('تعديل'),
                                      ),
                                    ),
                                  );
                                }
                                items.add(
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: ListTile(
                                      leading:
                                          Icon(Icons.delete, color: Colors.red),
                                      title: Text('حذف'),
                                    ),
                                  ),
                                );
                                return items;
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: canCreateReport
                                        ? () => _openReportEditor(p)
                                        : null,
                                    icon: const Icon(Icons.note_add_outlined),
                                    label: const Text('إنشاء تقرير'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: canViewReports
                                        ? () => _openReportsList(p)
                                        : null,
                                    icon: const Icon(Icons.article_outlined),
                                    label: Text(
                                      'استعرض التقرير'
                                      '${reportCount > 0 ? ' ($reportCount)' : ''}',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 60),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
