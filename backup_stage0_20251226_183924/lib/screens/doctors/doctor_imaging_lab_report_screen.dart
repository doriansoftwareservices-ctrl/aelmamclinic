// lib/screens/doctor_imaging_lab_report_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/db_service.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class DoctorImagingLabReportScreen extends StatefulWidget {
  const DoctorImagingLabReportScreen({Key? key}) : super(key: key);

  @override
  State<DoctorImagingLabReportScreen> createState() =>
      _DoctorImagingLabReportScreenState();
}

class _DoctorImagingLabReportScreenState
    extends State<DoctorImagingLabReportScreen> {
  DateTime? _startDate;
  DateTime? _endDate;

  List<Doctor> _allDoctors = [];
  List<Doctor> _filteredDoctors = [];
  Doctor? _selectedDoctor;
  bool _chooseNoDoctor = false;

  String _selectedCategory = 'all'; // all | radiology | lab

  List<_ServiceSummary> _serviceSummaries = [];

  bool _isLoading = false;

  final TextEditingController _doctorSearchCtrl = TextEditingController();

  int _totalCases = 0;
  double _totalCost = 0;
  double _totalShare = 0;

  @override
  void initState() {
    super.initState();
    _loadDoctors();
  }

  Future<void> _loadDoctors() async {
    final doctors = await DBService.instance.getAllDoctors();
    setState(() {
      _allDoctors = doctors;
      _filteredDoctors = doctors;
    });
  }

  Future<void> _pickCategory() async {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final Offset pos = box.localToGlobal(Offset.zero);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          pos.dx + box.size.width - 200, pos.dy + kToolbarHeight + 12, 12, 0),
      items: const [
        PopupMenuItem(value: 'all', child: Text('الكل')),
        PopupMenuItem(value: 'radiology', child: Text('الأشعة')),
        PopupMenuItem(value: 'lab', child: Text('المختبر')),
      ],
    );
    if (selected != null) setState(() => _selectedCategory = selected);
  }

  Future<void> _pickDoctor() async {
    _doctorSearchCtrl.clear();
    _filteredDoctors = List.from(_allDoctors);

    final chosen = await showDialog<Doctor>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            void doFilter(String query) {
              query = query.trim().toLowerCase();
              setStateDialog(() {
                _filteredDoctors = _allDoctors.where((doc) {
                  final inName = doc.name.toLowerCase().contains(query);
                  final inSpec =
                      doc.specialization.toLowerCase().contains(query);
                  final inPhone = doc.phoneNumber.toLowerCase().contains(query);
                  return inName || inSpec || inPhone;
                }).toList();
              });
            }

            return Directionality(
              textDirection: ui.TextDirection.rtl,
              child: AlertDialog(
                title: const Text('اختر الطبيب'),
                content: SizedBox(
                  width: 460,
                  height: 420,
                  child: Column(
                    children: [
                      TextField(
                        controller: _doctorSearchCtrl,
                        decoration: const InputDecoration(
                          hintText: 'بحث بالاسم/التخصص/الهاتف...',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: doFilter,
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: _filteredDoctors.isEmpty
                            ? const Center(child: Text('لا توجد نتائج'))
                            : ListView.builder(
                                itemCount: _filteredDoctors.length,
                                itemBuilder: (ctx2, index) {
                                  final d = _filteredDoctors[index];
                                  return ListTile(
                                    title: Text("د/${d.name}"),
                                    subtitle: Text(d.specialization),
                                    onTap: () => Navigator.pop(ctx, d),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('إلغاء'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _selectedDoctor = null;
                        _chooseNoDoctor = true;
                      });
                    },
                    child: const Text('بدون طبيب'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (chosen != null) {
      setState(() {
        _selectedDoctor = chosen;
        _chooseNoDoctor = false;
      });
    }
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _startDate = picked);
    }
  }

  Future<void> _pickEndDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _endDate = picked);
    }
  }

  Future<void> _generateReport() async {
    if (_startDate == null || _endDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء اختيار الفترة الزمنية أولاً')),
      );
      return;
    }
    setState(() {
      _isLoading = true;
      _serviceSummaries.clear();
      _totalCases = 0;
      _totalCost = 0;
      _totalShare = 0;
    });

    try {
      final allPatients = await DBService.instance.getAllPatients();
      final from =
          DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
      final to =
          DateTime(_endDate!.year, _endDate!.month, _endDate!.day, 23, 59, 59);

      bool Function(Patient) categoryFilter;
      if (_selectedCategory == 'all') {
        categoryFilter =
            (p) => p.serviceType == 'الأشعة' || p.serviceType == 'المختبر';
      } else if (_selectedCategory == 'radiology') {
        categoryFilter = (p) => p.serviceType == 'الأشعة';
      } else {
        categoryFilter = (p) => p.serviceType == 'المختبر';
      }

      final filtered = allPatients.where((p) {
        final dateOk =
            p.registerDate.isAfter(from.subtract(const Duration(days: 1))) &&
                p.registerDate.isBefore(to.add(const Duration(days: 1)));
        bool doctorOk = true;
        if (_chooseNoDoctor) {
          doctorOk = p.doctorId == null;
        } else if (_selectedDoctor != null) {
          doctorOk = p.doctorId == _selectedDoctor!.id;
        }
        return dateOk && categoryFilter(p) && doctorOk;
      }).toList();

      final Map<String, _ServiceSummary> map = {};
      for (var pat in filtered) {
        final key = pat.serviceName ?? 'غير معروف';
        map[key] ??= _ServiceSummary(serviceName: key);
        map[key]!.count++;
        map[key]!.sumCost += pat.serviceCost ?? 0;
        map[key]!.sumShare += pat.doctorShare;
      }

      int totalCases = 0;
      double totalCost = 0;
      double totalShare = 0;
      for (var s in map.values) {
        totalCases += s.count;
        totalCost += s.sumCost;
        totalShare += s.sumShare;
      }

      setState(() {
        _serviceSummaries = map.values.toList()
          ..sort((a, b) => a.serviceName.compareTo(b.serviceName));
        _totalCases = totalCases;
        _totalCost = totalCost;
        _totalShare = totalShare;
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _showPatientsOfService(String serviceName) async {
    if (_startDate == null || _endDate == null) return;

    final allPatients = await DBService.instance.getAllPatients();
    final from = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
    final to =
        DateTime(_endDate!.year, _endDate!.month, _endDate!.day, 23, 59, 59);

    bool Function(Patient) categoryFilter;
    if (_selectedCategory == 'all') {
      categoryFilter =
          (p) => p.serviceType == 'الأشعة' || p.serviceType == 'المختبر';
    } else if (_selectedCategory == 'radiology') {
      categoryFilter = (p) => p.serviceType == 'الأشعة';
    } else {
      categoryFilter = (p) => p.serviceType == 'المختبر';
    }

    final filtered = allPatients.where((p) {
      final dateOk =
          p.registerDate.isAfter(from.subtract(const Duration(days: 1))) &&
              p.registerDate.isBefore(to.add(const Duration(days: 1)));
      bool doctorOk = true;
      if (_chooseNoDoctor) {
        doctorOk = p.doctorId == null;
      } else if (_selectedDoctor != null) {
        doctorOk = p.doctorId == _selectedDoctor!.id;
      }
      return categoryFilter(p) &&
          p.serviceName == serviceName &&
          dateOk &&
          doctorOk;
    }).toList();

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeuCard(
                padding: const EdgeInsets.all(12),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.medical_information_rounded,
                      color: kPrimaryColor),
                  title: Text(
                    "الخدمة: $serviceName",
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text("عدد المرضى: ${filtered.length}"),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: filtered.isEmpty
                    ? const Center(child: Text('لا توجد بيانات'))
                    : ListView.separated(
                        shrinkWrap: true,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final pat = filtered[i];
                          return NeuCard(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                "المريض: ${pat.name}",
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800),
                              ),
                              subtitle: Text(
                                "التكلفة: ${pat.serviceCost?.toStringAsFixed(2) ?? '0.00'}",
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: .7),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              trailing: Text(
                                "حصة: ${pat.doctorShare.toStringAsFixed(2)}",
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900),
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
    );
  }

  void _resetAll() {
    setState(() {
      _selectedCategory = 'all';
      _selectedDoctor = null;
      _chooseNoDoctor = false;
      _startDate = null;
      _endDate = null;
      _serviceSummaries.clear();
      _totalCases = 0;
      _totalCost = 0;
      _totalShare = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final startLabel = _startDate == null
        ? 'من تاريخ'
        : DateFormat('yyyy-MM-dd').format(_startDate!);
    final endLabel = _endDate == null
        ? 'إلى تاريخ'
        : DateFormat('yyyy-MM-dd').format(_endDate!);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/images/logo.png',
                  height: 24,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              const SizedBox(width: 8),
              const Text('تقرير الأشعة والمختبر للأطباء'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'إعادة تهيئة',
              onPressed: _resetAll,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              children: [
                // رأس الشاشة
                NeuCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.insights_rounded,
                            color: kPrimaryColor, size: 26),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'فلترة وعرض ملخّص الخدمات حسب الطبيب والفترة',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // شريط المرشّحات
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      NeuButton.flat(
                        label: _selectedCategory == 'all'
                            ? 'الكل'
                            : _selectedCategory == 'radiology'
                                ? 'الأشعة'
                                : 'المختبر',
                        icon: Icons.segment_rounded,
                        onPressed: _pickCategory,
                      ),
                      const SizedBox(width: 10),
                      NeuButton.flat(
                        label: _chooseNoDoctor
                            ? 'بدون طبيب'
                            : _selectedDoctor == null
                                ? 'كل الأطباء'
                                : 'د/${_selectedDoctor!.name}',
                        icon: Icons.medical_services_rounded,
                        onPressed: _pickDoctor,
                      ),
                      const SizedBox(width: 10),
                      _DateTile(
                          label: 'من تاريخ',
                          value: startLabel,
                          onTap: _pickStartDate),
                      const SizedBox(width: 10),
                      _DateTile(
                          label: 'إلى تاريخ',
                          value: endLabel,
                          onTap: _pickEndDate),
                      const SizedBox(width: 10),
                      NeuButton.primary(
                        label: 'عرض',
                        icon: Icons.play_arrow_rounded,
                        onPressed: _generateReport,
                      ),
                      const SizedBox(width: 10),
                      NeuButton.flat(
                        label: 'تفريغ التاريخ',
                        icon: Icons.close_rounded,
                        onPressed: () => setState(() {
                          _startDate = null;
                          _endDate = null;
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // المحتوى
                if (_isLoading)
                  const Expanded(
                      child: Center(child: CircularProgressIndicator()))
                else if (_serviceSummaries.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        'لا توجد بيانات',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: .6),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Column(
                      children: [
                        // إجماليات
                        NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              const Icon(Icons.summarize_rounded,
                                  color: kPrimaryColor),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'الحالات: $_totalCases  •  التكلفة: ${_totalCost.toStringAsFixed(2)}  •  حصة الأطباء: ${_totalShare.toStringAsFixed(2)}',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),

                        // القائمة
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: _serviceSummaries.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final s = _serviceSummaries[index];
                              return NeuCard(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                onTap: () =>
                                    _showPatientsOfService(s.serviceName),
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Container(
                                    decoration: BoxDecoration(
                                      color:
                                          kPrimaryColor.withValues(alpha: .1),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.all(8),
                                    child: const Icon(Icons.biotech_rounded,
                                        color: kPrimaryColor, size: 22),
                                  ),
                                  title: Text(
                                    s.serviceName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      'عدد الحالات: ${s.count}  •  إجمالي التكلفة: ${s.sumCost.toStringAsFixed(2)}',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: .65),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  trailing: Text(
                                    'حصة: ${s.sumShare.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
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

class _DateTile extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DateTile({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.event_rounded, color: kPrimaryColor),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 13.5)),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .8),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_left_rounded),
        ],
      ),
    );
  }
}

class _ServiceSummary {
  final String serviceName;
  int count;
  double sumCost;
  double sumShare;

  _ServiceSummary({
    required this.serviceName,
  })  : count = 0,
        sumCost = 0.0,
        sumShare = 0.0;
}
