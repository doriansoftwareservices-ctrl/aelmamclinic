// lib/screens/doctors/patients_by_doctor_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:ui' as ui show TextDirection;
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/export_service.dart';
import 'package:aelmamclinic/screens/patients/view_patient_screen.dart';
import 'package:aelmamclinic/screens/patients/edit_patient_screen.dart';
import 'package:aelmamclinic/screens/patients/duplicate_patients_screen.dart';

class PatientsByDoctorScreen extends StatefulWidget {
  final Doctor doctor;
  const PatientsByDoctorScreen({super.key, required this.doctor});

  @override
  State<PatientsByDoctorScreen> createState() => _PatientsByDoctorScreenState();
}

class _PatientsByDoctorScreenState extends State<PatientsByDoctorScreen> {
  List<Patient> _patients = [];
  List<Patient> _filteredPatients = [];

  final TextEditingController _searchController = TextEditingController();
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    _loadPatientsByDoctor();
    _searchController.addListener(_filterPatients);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPatientsByDoctor() async {
    final allPatients = await DBService.instance.getAllPatients();
    final filtered =
        allPatients.where((p) => p.doctorId == widget.doctor.id).toList();
    setState(() {
      _patients = filtered;
      _filteredPatients = filtered;
    });
  }

  bool _isWithinDateRange(DateTime date) {
    bool inRange = true;
    if (_startDate != null) inRange = !date.isBefore(_startDate!);
    if (_endDate != null && inRange) inRange = !date.isAfter(_endDate!);
    return inRange;
  }

  void _filterPatients() {
    final q = _searchController.text.toLowerCase();
    setState(() {
      _filteredPatients = _patients.where((p) {
        final match = p.name.toLowerCase().contains(q) ||
            p.phoneNumber.toLowerCase().contains(q);
        return match && _isWithinDateRange(p.registerDate);
      }).toList();
    });
  }

  Future<void> _pickStartDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _startDate = DateTime(d.year, d.month, d.day));
      _filterPatients();
    }
  }

  Future<void> _pickEndDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _endDate = DateTime(d.year, d.month, d.day));
      _filterPatients();
    }
  }

  void _resetFilterDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _filterPatients();
  }

  Future<void> _makePhoneCall(String phoneNumber) async {
    final uri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يمكن إجراء المكالمة')),
      );
    }
  }

  Future<void> _shareExcelFile() async {
    if (_filteredPatients.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للمشاركة')),
      );
      return;
    }
    try {
      final bytes =
          await ExportService.exportPatientsToExcel(_filteredPatients);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/قائمة-مرضى-د_${widget.doctor.name}.xlsx');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'قائمة المرضى للطبيب ${widget.doctor.name}',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء المشاركة: $e')),
      );
    }
  }

  Future<void> _downloadExcelFile() async {
    if (_filteredPatients.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للتنزيل')),
      );
      return;
    }
    try {
      final bytes =
          await ExportService.exportPatientsToExcel(_filteredPatients);
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/قائمة-مرضى-د_${widget.doctor.name}.xlsx';
      final file = File(path);
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم التنزيل إلى: $path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء التنزيل: $e')),
      );
    }
  }

  Future<void> _deletePatient(int id) async {
    await DBService.instance.deletePatient(id);
    _loadPatientsByDoctor();
  }

  @override
  Widget build(BuildContext context) {
    // تجميع المرضى حسب رقم الهاتف (للكشف عن التكرارات)
    final Map<String, List<Patient>> grouped = {};
    for (var p in _filteredPatients) {
      grouped.putIfAbsent(p.phoneNumber, () => []).add(p);
    }

    final groups = grouped.values.toList();
    final uniqueCount = grouped.length;
    final casesCount = _filteredPatients.length;
    final totalAmount = _filteredPatients
        .fold<double>(0.0, (sum, p) => sum + p.paidAmount)
        .toStringAsFixed(2);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.groups_rounded),
              const SizedBox(width: 8),
              Text('مرضى د/ ${widget.doctor.name}'),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.share_rounded),
              tooltip: 'مشاركة Excel',
              onPressed: _shareExcelFile,
            ),
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'تنزيل Excel',
              onPressed: _downloadExcelFile,
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              children: [
                // بحث
                NeuField(
                  controller: _searchController,
                  hintText: 'ابحث عن المريض أو رقم الهاتف',
                  prefix: const Icon(Icons.search_rounded),
                ),
                const SizedBox(height: 12),

                // شريط أدوات التصفية بالتواريخ
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _pickStartDate,
                        icon: const Icon(Icons.calendar_today_rounded),
                        label: Text(
                          _startDate == null
                              ? 'من تاريخ'
                              : DateFormat('yyyy-MM-dd').format(_startDate!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _pickEndDate,
                        icon: const Icon(Icons.calendar_month_rounded),
                        label: Text(
                          _endDate == null
                              ? 'إلى تاريخ'
                              : DateFormat('yyyy-MM-dd').format(_endDate!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _resetFilterDates,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('تفريغ'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // بطاقة الإحصاءات السريعة
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _StatPill(label: 'عدد المرضى', value: '$uniqueCount'),
                        const SizedBox(width: 12),
                        _StatPill(label: 'عدد الحالات', value: '$casesCount'),
                        const SizedBox(width: 12),
                        _StatPill(label: 'المبلغ الإجمالي', value: totalAmount),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // القائمة
                Expanded(
                  child: groups.isEmpty
                      ? Center(
                          child: Text(
                            'لا توجد نتائج',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: .6),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: groups.length,
                          itemBuilder: (context, index) {
                            final group = groups[index];
                            final patient = group[0];
                            final totalPaid = group.fold<double>(
                              0.0,
                              (sum, p) => sum + p.paidAmount,
                            );

                            return NeuCard(
                              margin: const EdgeInsets.symmetric(vertical: 6.0),
                              child: ListTile(
                                onTap: () {
                                  if (group.length > 1) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => DuplicatePatientsScreen(
                                          phoneNumber: patient.phoneNumber,
                                          patientName: patient.name,
                                        ),
                                      ),
                                    );
                                  } else {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            ViewPatientScreen(patient: patient),
                                      ),
                                    ).then((_) => _loadPatientsByDoctor());
                                  }
                                },
                                leading: Container(
                                  decoration: BoxDecoration(
                                    color: kPrimaryColor.withValues(alpha: .10),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.all(10),
                                  child: const Icon(
                                    Icons.person_outline_rounded,
                                    color: kPrimaryColor,
                                  ),
                                ),
                                title: Text(
                                  patient.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                subtitle: Text(
                                  group.length > 1
                                      ? 'المبلغ المدفوع: $totalPaid'
                                      : '${patient.diagnosis}\nالمبلغ المدفوع: $totalPaid',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(
                                          alpha: .7,
                                        ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing: PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert_rounded),
                                  onSelected: (value) {
                                    switch (value) {
                                      case 'call':
                                        if (patient.phoneNumber.isNotEmpty) {
                                          _makePhoneCall(patient.phoneNumber);
                                        } else {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            const SnackBar(
                                              content: Text('لا يوجد رقم هاتف'),
                                            ),
                                          );
                                        }
                                        break;
                                      case 'edit':
                                        if (group.length == 1) {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => EditPatientScreen(
                                                patient: patient,
                                              ),
                                            ),
                                          ).then(
                                              (_) => _loadPatientsByDoctor());
                                        }
                                        break;
                                      case 'delete':
                                        _deletePatient(patient.id!);
                                        break;
                                    }
                                  },
                                  itemBuilder: (ctx) {
                                    final items = <PopupMenuEntry<String>>[
                                      PopupMenuItem(
                                        value: 'call',
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.phone_rounded,
                                              size: 20,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                            ),
                                            const SizedBox(width: 8),
                                            const Text('اتصال'),
                                          ],
                                        ),
                                      ),
                                      if (group.length == 1)
                                        PopupMenuItem(
                                          value: 'edit',
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.edit_rounded,
                                                size: 20,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .primary,
                                              ),
                                              const SizedBox(width: 8),
                                              const Text('تعديل'),
                                            ],
                                          ),
                                        ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Row(
                                          children: const [
                                            Icon(
                                              Icons.delete_rounded,
                                              size: 20,
                                              color: Colors.red,
                                            ),
                                            SizedBox(width: 8),
                                            Text('حذف'),
                                          ],
                                        ),
                                      ),
                                    ];
                                    return items;
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  const _StatPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: .25),
        ),
      ),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              color:
                  Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}
