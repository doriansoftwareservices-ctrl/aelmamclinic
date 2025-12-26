// lib/services/doctors_shares_list_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

/*── البيانات ─*/
import 'package:aelmamclinic/models/doctor.dart';
import 'db_service.dart';

class DoctorsSharesListScreen extends StatefulWidget {
  const DoctorsSharesListScreen({super.key});

  @override
  State<DoctorsSharesListScreen> createState() =>
      _DoctorsSharesListScreenState();
}

class _DoctorsSharesListScreenState extends State<DoctorsSharesListScreen> {
  final _searchController = TextEditingController();

  bool _loading = true;
  String? _error;

  List<Doctor> _allDoctors = [];
  List<Doctor> _filteredDoctors = [];

  @override
  void initState() {
    super.initState();
    _loadDoctors();
    _searchController.addListener(_filterDoctors);
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterDoctors);
    _searchController.dispose();
    super.dispose();
  }

  /*────────────────── البيانات ──────────────────*/
  Future<void> _loadDoctors() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final doctors = await DBService.instance.getAllDoctors();
      setState(() {
        _allDoctors = doctors;
        _filteredDoctors = doctors;
      });
    } catch (e) {
      setState(() => _error = 'فشل تحميل الأطباء: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filterDoctors() {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() => _filteredDoctors = List.of(_allDoctors));
      return;
    }
    setState(() {
      _filteredDoctors = _allDoctors.where((doc) {
        final name = (doc.name).toLowerCase();
        final spec = (doc.specialization).toLowerCase();
        final phone = (doc.phoneNumber).toLowerCase();
        return name.contains(q) || spec.contains(q) || phone.contains(q);
      }).toList();
    });
  }

  /*────────────────── اختيار نوع الخدمات ──────────────────*/
  void _chooseServiceType(Doctor doc) {
    final scheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('النِّسَب للطبيب: د/${doc.name}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        content: const Text('اختر نوع الخدمات المراد عرضها:'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إغلاق'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showDoctorSharesBottomSheet(doc, 'radiology');
            },
            child: const Text('الأشعة'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showDoctorSharesBottomSheet(doc, 'lab');
            },
            child: const Text('المختبر'),
          ),
        ],
      ),
    );
  }

  void _showDoctorSharesBottomSheet(Doctor doc, String serviceType) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => DoctorSharesByTypeWidget(
        doctor: doc,
        serviceType: serviceType,
      ),
    );
  }

  /*──────── بناء محتوى الجسم بدون if/else داخل القوائم ────────*/
  List<Widget> _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const [
        SizedBox(height: 100),
        Center(child: CircularProgressIndicator()),
      ];
    }
    if (_error != null) {
      return [
        _ErrorCard(message: _error!, onRetry: _loadDoctors),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsetsDirectional.only(start: 6, bottom: 8),
        child: Text(
          'الأطباء: ${_filteredDoctors.length}',
          style: TextStyle(
            color: scheme.onSurface.withValues(alpha: .6),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      if (_filteredDoctors.isEmpty)
        const Center(child: Text('لا توجد نتائج'))
      else
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _filteredDoctors.map((doctor) {
            return SizedBox(
              width: 520,
              child: NeuCard(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: CircleAvatar(
                      radius: 24,
                      backgroundColor: kPrimaryColor.withValues(alpha: .12),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Image.asset(
                          'assets/images/doctor.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.person, color: kPrimaryColor),
                        ),
                      ),
                    ),
                  ),
                  title: Text(
                    'د/ ${doctor.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    doctor.specialization,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .75)),
                  ),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () => _chooseServiceType(doctor),
                ),
              ),
            );
          }).toList(),
        ),
    ];
  }

  /*────────────────── الواجهة ──────────────────*/
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
              tooltip: 'تحديث',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loadDoctors,
            ),
          ],
        ),
        body: SafeArea(
          child: RefreshIndicator(
            color: scheme.primary,
            onRefresh: _loadDoctors,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: [
                /*──────── رأس الصفحة ────────*/
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.percent_rounded,
                            color: kPrimaryColor, size: 22),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'النِّسَب الخاصة بالأطباء',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                /*──────── شريط البحث (TBIAN) ────────*/
                TSearchField(
                  controller: _searchController,
                  hint: 'ابحث عن الطبيب (الاسم/التخصص/الهاتف)…',
                  onChanged: (_) => _filterDoctors(),
                  onClear: () {
                    _searchController.clear();
                    _filterDoctors();
                  },
                ),

                const SizedBox(height: 12),

                // بقية المحتوى
                ..._buildBody(scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/*────────────────── BottomSheet: نسب الطبيب حسب النوع ──────────────────*/
class DoctorSharesByTypeWidget extends StatefulWidget {
  final Doctor doctor;
  final String serviceType; // 'radiology' أو 'lab'

  const DoctorSharesByTypeWidget({
    super.key,
    required this.doctor,
    required this.serviceType,
  });

  @override
  State<DoctorSharesByTypeWidget> createState() =>
      _DoctorSharesByTypeWidgetState();
}

class _DoctorSharesByTypeWidgetState extends State<DoctorSharesByTypeWidget> {
  late String _typeLabel;
  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _servicesWithShare = [];

  @override
  void initState() {
    super.initState();
    _typeLabel = (widget.serviceType == 'radiology') ? 'الأشعة' : 'المختبر';
    _loadServices();
  }

  Future<void> _loadServices() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = await DBService.instance.database;
      final sql = '''
        SELECT
          ms.id   AS serviceId,
          ms.name AS serviceName,
          ms.cost AS serviceCost,
          sds.id  AS shareId,
          sds.sharePercentage
        FROM medical_services ms
        LEFT JOIN service_doctor_share sds
          ON sds.serviceId = ms.id
         AND sds.doctorId = ?
        WHERE ms.serviceType = ?
        ORDER BY ms.id DESC
      ''';
      final res =
          await db.rawQuery(sql, [widget.doctor.id, widget.serviceType]);
      setState(() {
        _servicesWithShare = res;
      });
    } catch (e) {
      setState(() => _error = 'فشل تحميل الخدمات: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addOrEditShare({
    required int serviceId,
    int? shareId,
    double? currentPercentage,
  }) async {
    final isEditMode = (shareId != null);
    final controller = TextEditingController(
      text: currentPercentage == null ? '' : currentPercentage.toString(),
    );

    await showDialog(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: scheme.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(isEditMode ? 'تعديل نسبة الطبيب' : 'إضافة نسبة الطبيب'),
          content: NeuField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            labelText: 'النسبة (%)',
            hintText: 'مثال: 10 يعني 10%',
            prefix: const Icon(Icons.percent_rounded),
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                final val = double.tryParse(controller.text.trim()) ?? 0.0;
                if (val <= 0) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('الرجاء إدخال نسبة صحيحة')),
                  );
                  return;
                }
                if (isEditMode) {
                  await DBService.instance.updateServiceDoctorShare(
                    id: shareId,
                    sharePercentage: val,
                  );
                } else {
                  await DBService.instance.insertServiceDoctorShare(
                    serviceId: serviceId,
                    doctorId: widget.doctor.id!,
                    sharePercentage: val,
                  );
                }
                if (!mounted) return;
                Navigator.pop(ctx);
                await _loadServices();
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteShare(int shareId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: scheme.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('تأكيد الحذف'),
          content: const Text('هل تريد حذف هذه النسبة؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف'),
            ),
          ],
        );
      },
    );
    if (confirm == true) {
      await DBService.instance.deleteServiceDoctorShare(shareId);
      await _loadServices();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.of(context).size.height * 0.85;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            // رأس الـ BottomSheet
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: const Icon(Icons.person, color: kPrimaryColor),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('د/${widget.doctor.name}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w900)),
                          Text('الخدمات ($_typeLabel)',
                              style: TextStyle(
                                  color:
                                      scheme.onSurface.withValues(alpha: .75))),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'إغلاق',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 12),

            // المحتوى
            if (_loading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Expanded(
                child: _ErrorCard(
                  message: _error!,
                  onRetry: _loadServices,
                ),
              )
            else if (_servicesWithShare.isEmpty)
              Expanded(
                child: Center(
                  child: Text('لا توجد خدمات ($_typeLabel) بعد',
                      style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: .65))),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: _servicesWithShare.length,
                  itemBuilder: (ctx, index) {
                    final item = _servicesWithShare[index];

                    final serviceId = item['serviceId'] as int;
                    final serviceName = item['serviceName'] as String;
                    final serviceCostNum = (item['serviceCost'] as num?) ?? 0;
                    final serviceCost = serviceCostNum.toDouble();
                    final shareId = item['shareId'] as int?;
                    final sharePctNum = (item['sharePercentage'] as num?);
                    final sharePercentage = sharePctNum?.toDouble();

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: NeuCard(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              serviceName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 16),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TInfoCard(
                                    icon: Icons.attach_money_rounded,
                                    label: 'السعر',
                                    value: serviceCost.toStringAsFixed(2),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TInfoCard(
                                    icon: Icons.percent_rounded,
                                    label: 'نسبة الطبيب',
                                    value:
                                        '${(sharePercentage ?? 0).toStringAsFixed(2)} %',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TOutlinedButton(
                                    icon: Icons.edit_rounded,
                                    label: shareId == null
                                        ? 'إضافة نسبة'
                                        : 'تعديل النسبة',
                                    onPressed: () => _addOrEditShare(
                                      serviceId: serviceId,
                                      shareId: shareId,
                                      currentPercentage: sharePercentage,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                if (shareId != null)
                                  NeuButton.flat(
                                    icon: Icons.delete_outline_rounded,
                                    label: 'حذف',
                                    onPressed: () => _deleteShare(shareId),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/*──────── بطاقة خطأ بنمط TBIAN ────────*/
class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
            label: const Text('إعادة المحاولة',
                style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: scheme.error,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }
}
