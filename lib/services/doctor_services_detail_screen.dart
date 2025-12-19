// lib/features/doctors/doctor_services_detail_screen.dart
import 'dart:io';
import 'dart:ui' as ui show TextDirection;

import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'db_service.dart';
import 'package:aelmamclinic/models/doctor.dart';

class DoctorServicesDetailScreen extends StatefulWidget {
  final Doctor doctor;

  const DoctorServicesDetailScreen({super.key, required this.doctor});

  @override
  State<DoctorServicesDetailScreen> createState() =>
      _DoctorServicesDetailScreenState();
}

class _DoctorServicesDetailScreenState
    extends State<DoctorServicesDetailScreen> {
  // حقول الإدخال لنموذج الإضافة/التعديل
  final _serviceNameCtrl = TextEditingController();
  final _serviceCostCtrl = TextEditingController();
  final _towerShareCtrl = TextEditingController();

  // البحث الداخلي
  final _searchCtrl = TextEditingController();

  // البيانات من القاعدة
  List<Map<String, dynamic>> _doctorServices = [];
  List<Map<String, dynamic>> _filtered = [];

  bool _showHidden = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadDoctorServices();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _serviceNameCtrl.dispose();
    _serviceCostCtrl.dispose();
    _towerShareCtrl.dispose();
    _searchCtrl.removeListener(_applyFilter);
    _searchCtrl.dispose();
    super.dispose();
  }

  /*────────────────── أدوات مساعدة ──────────────────*/
  double _parseDouble(String s) {
    // دعم الفاصلة العربية كفاصل عشري
    final v = s.trim().replaceAll(',', '.');
    return double.tryParse(v) ?? 0.0;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /*────────────────── تحميل / فلترة ──────────────────*/
  Future<void> _loadDoctorServices() async {
    setState(() => _busy = true);
    try {
      final db = await DBService.instance.database;
      final hiddenFilter = _showHidden ? '' : 'AND sds.isHidden = 0';
      // ندعم أكثر من صيغة للـ serviceType تحسبًا لبيانات قديمة/مستوردة
      final sql = '''
        SELECT
          ms.id,
          ms.name,
          ms.cost,
          sds.id AS shareId,
          sds.towerSharePercentage,
          sds.isHidden
        FROM medical_services ms
        JOIN service_doctor_share sds
          ON sds.serviceId = ms.id
        WHERE ms.serviceType IN ('doctorGeneral','doctor','طبيب')
          AND sds.doctorId = ?
          $hiddenFilter
        ORDER BY ms.id DESC
      ''';
      final res = await db.rawQuery(sql, [widget.doctor.id]);
      setState(() {
        _doctorServices = res;
      });
      _applyFilter();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filtered = List<Map<String, dynamic>>.from(_doctorServices);
      } else {
        _filtered = _doctorServices.where((e) {
          final name = (e['name'] ?? '').toString().toLowerCase();
          return name.contains(q);
        }).toList();
      }
    });
  }

  /*────────────────── إخفاء/استرداد ──────────────────*/
  Future<void> _toggleHidden(int shareId, bool hide) async {
    await DBService.instance.updateServiceDoctorShareHidden(
      id: shareId,
      isHidden: hide ? 1 : 0,
    );
    await _loadDoctorServices();
    _toast(hide ? 'تم إخفاء الخدمة' : 'تم إظهار الخدمة');
  }

  /*────────────────── إضافة/تعديل خدمة ──────────────────*/
  Future<void> _addOrEditService({int? serviceId}) async {
    final isEditMode = serviceId != null;
    String? initialName;
    double? initialCost;
    double? initialTowerShare;
    int? shareId;

    if (isEditMode) {
      final old = _doctorServices.firstWhere(
        (e) => e['id'] == serviceId && e['shareId'] != null,
        orElse: () => {},
      );
      if (old.isNotEmpty) {
        initialName = (old['name'] as String?) ?? '';
        initialCost = (old['cost'] as num?)?.toDouble();
        initialTowerShare = (old['towerSharePercentage'] as num?)?.toDouble();
        shareId = old['shareId'] as int?;
      }
    }

    _serviceNameCtrl.text = initialName ?? '';
    _serviceCostCtrl.text =
        initialCost != null ? initialCost.toStringAsFixed(2) : '';
    _towerShareCtrl.text =
        initialTowerShare != null ? initialTowerShare.toStringAsFixed(2) : '';

    await showDialog(
      context: context,
      builder: (ctx) {
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: AlertDialog(
            title: Text(isEditMode ? 'تعديل خدمة للطبيب' : 'إضافة خدمة للطبيب'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NeuField(
                    controller: _serviceNameCtrl,
                    labelText: 'اسم الخدمة',
                    prefix: const Icon(Icons.medical_services_outlined),
                  ),
                  const SizedBox(height: 10),
                  NeuField(
                    controller: _serviceCostCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    labelText: 'مبلغ الخدمة',
                    prefix: const Icon(Icons.attach_money_rounded),
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  NeuField(
                    controller: _towerShareCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    labelText: 'نسبة المركز الطبي (%)',
                    prefix: const Icon(Icons.percent_rounded),
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () async {
                  final name = _serviceNameCtrl.text.trim();
                  final cost = _parseDouble(_serviceCostCtrl.text);
                  final towerShare = _parseDouble(_towerShareCtrl.text);

                  if (name.isEmpty || cost <= 0) {
                    _toast('الرجاء إدخال اسم خدمة ومبلغ صحيح (> 0)');
                    return;
                  }
                  if (towerShare < 0 || towerShare > 100) {
                    _toast('نسبة المركز يجب أن تكون بين 0 و 100');
                    return;
                  }

                  if (isEditMode && shareId != null) {
                    final int currentServiceId = serviceId;
                    await DBService.instance.updateMedicalService(
                      id: currentServiceId,
                      name: name,
                      cost: cost,
                      serviceType: 'doctorGeneral',
                    );
                    await DBService.instance.updateServiceDoctorShare(
                      id: shareId,
                      towerSharePercentage: towerShare,
                    );
                  } else {
                    final newId = await DBService.instance.insertMedicalService(
                      name: name,
                      cost: cost,
                      serviceType: 'doctorGeneral',
                    );
                    await DBService.instance.insertServiceDoctorShare(
                      serviceId: newId,
                      doctorId: widget.doctor.id!,
                      // في خدمات الطبيب: نستخدم towerSharePercentage لنسبة المركز
                      // ونبقي sharePercentage غير مؤثر (0) كونه يُستخدم للأشعة/المختبر.
                      sharePercentage: 0.0,
                      towerSharePercentage: towerShare,
                    );
                  }

                  if (!mounted) return;
                  Navigator.pop(ctx);
                  await _loadDoctorServices();
                },
                child: const Text('حفظ'),
              ),
            ],
          ),
        );
      },
    );
  }

  /*────────────────── استيراد من Excel ──────────────────*/
  Future<void> _importServicesFromExcel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );
    if (result == null || result.files.single.path == null) return;

    setState(() => _busy = true);
    try {
      final bytes = File(result.files.single.path!).readAsBytesSync();
      final excel = Excel.decodeBytes(bytes);

      // أسماء موجودة مسبقاً للطبيب الحالي (حسّاس/غير حسّاس لحالة الأحرف)
      final existingNamesLower = _doctorServices
          .map((e) => (e['name'] ?? '').toString().trim().toLowerCase())
          .toSet();

      int inserted = 0;

      for (final table in excel.tables.keys) {
        final rows = excel.tables[table]!.rows;
        for (final row in rows) {
          if (row.length < 3) continue;

          final nameRaw = (row[0]?.value?.toString() ?? '').trim();
          final costRaw = (row[1]?.value?.toString() ?? '').trim();
          final shareRaw = (row[2]?.value?.toString() ?? '').trim();

          // تخطّي الصفوف الفارغة أو رؤوس الأعمدة
          final lower = nameRaw.toLowerCase();
          if (nameRaw.isEmpty ||
              lower == 'name' ||
              lower == 'service' ||
              lower == 'اسم' ||
              lower == 'الخدمة') {
            continue;
          }

          final cost = _parseDouble(costRaw);
          final towerShare = _parseDouble(shareRaw);

          if (cost <= 0 || towerShare < 0 || towerShare > 100) continue;
          if (existingNamesLower.contains(lower)) continue;

          // ⬅️ نُنشئ الخدمة كـ doctorGeneral (متوافق مع الإدخال اليدوي)
          final newId = await DBService.instance.insertMedicalService(
            name: nameRaw,
            cost: cost,
            serviceType: 'doctorGeneral',
          );

          // ⬅️ نربطها بالطبيب: نسبة المركز في towerSharePercentage
          await DBService.instance.insertServiceDoctorShare(
            serviceId: newId,
            doctorId: widget.doctor.id!,
            sharePercentage: 0.0, // غير مستخدم لخدمات الطبيب
            towerSharePercentage: towerShare,
          );

          existingNamesLower.add(lower);
          inserted++;
        }
      }

      await _loadDoctorServices();
      _toast(inserted > 0
          ? 'تم استيراد $inserted خدمة بنجاح'
          : 'لم يتم استيراد أي صف صالح');
    } catch (e) {
      _toast('فشل استيراد الملف: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              tooltip:
                  _showHidden ? 'إخفاء العناصر المخفية' : 'عرض العناصر المخفية',
              icon: Icon(_showHidden
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded),
              onPressed: () {
                setState(() => _showHidden = !_showHidden);
                _loadDoctorServices();
              },
            ),
            IconButton(
              tooltip: 'استيراد من Excel',
              icon: const Icon(Icons.upload_file_rounded),
              onPressed: _busy ? null : _importServicesFromExcel,
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                children: [
                  // رأس الصفحة بهوية الشاشة وفق TBIAN
                  NeuCard(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: kPrimaryColor.withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.all(8),
                          child: const Icon(Icons.local_hospital_outlined,
                              color: kPrimaryColor, size: 20),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'خدمات د/${widget.doctor.name}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w900, fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // شريط أدوات سريع (بحث + إضافة)
                  Row(
                    children: [
                      Expanded(
                        child: TSearchField(
                          controller: _searchCtrl,
                          hint: 'ابحث باسم الخدمة…',
                          onChanged: (_) => _applyFilter(),
                          onClear: () {
                            _searchCtrl.clear();
                            _applyFilter();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      NeuButton.flat(
                        icon: Icons.add_rounded,
                        label: 'إضافة خدمة',
                        onPressed: _busy ? null : () => _addOrEditService(),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  const TSectionHeader('قائمة الخدمات'),

                  // القائمة
                  if (_busy) ...[
                    const SizedBox(height: 80),
                    const Center(child: CircularProgressIndicator()),
                  ] else if (_filtered.isEmpty) ...[
                    const SizedBox(height: 80),
                    const Center(child: Text('لا توجد خدمات لهذا الطبيب')),
                  ] else ...[
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: _filtered.map((item) {
                        final serviceId = item['id'] as int;
                        final shareId = item['shareId'] as int;
                        final name = item['name'] as String;
                        final cost = (item['cost'] as num).toDouble();
                        final towerShare =
                            (item['towerSharePercentage'] as num).toDouble();
                        final hidden = (item['isHidden'] as int) == 1;

                        final badge = Container(
                          decoration: BoxDecoration(
                            color: hidden
                                ? scheme.errorContainer
                                : kPrimaryColor.withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                hidden
                                    ? Icons.visibility_off_rounded
                                    : Icons.check_circle_rounded,
                                size: 16,
                                color: hidden
                                    ? scheme.onErrorContainer
                                    : kPrimaryColor,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                hidden ? 'مخفية' : 'فعّالة',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: hidden
                                      ? scheme.onErrorContainer
                                      : kPrimaryColor,
                                ),
                              ),
                            ],
                          ),
                        );

                        return SizedBox(
                          width: 480, // عرض مناسب داخل Wrap
                          child: NeuCard(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: hidden
                                              ? scheme.onSurface
                                                  .withValues(alpha: .55)
                                              : scheme.onSurface,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    badge,
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TInfoCard(
                                        icon: Icons.attach_money_rounded,
                                        label: 'السعر',
                                        value: cost.toStringAsFixed(2),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TInfoCard(
                                        icon: Icons.percent_rounded,
                                        label: 'نسبة المركز',
                                        value:
                                            '${towerShare.toStringAsFixed(2)} %',
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
                                        label: 'تعديل',
                                        onPressed: () => _addOrEditService(
                                            serviceId: serviceId),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    NeuButton.flat(
                                      icon: hidden
                                          ? Icons.visibility_rounded
                                          : Icons.visibility_off_rounded,
                                      label: hidden ? 'استرداد' : 'إخفاء',
                                      onPressed: () =>
                                          _toggleHidden(shareId, !hidden),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
              if (_busy)
                Positioned.fill(
                  child: Container(
                    color: scheme.scrim.withValues(alpha: .06),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
