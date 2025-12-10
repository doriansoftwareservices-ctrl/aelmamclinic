// lib/screens/service_doctor_share_screen.dart

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/core/formatters.dart';

/*── البيانات ─*/
import 'package:aelmamclinic/models/doctor.dart';
import 'db_service.dart';

class ServiceDoctorShareScreen extends StatefulWidget {
  final int serviceId;
  final String serviceName;
  final double serviceCost;

  const ServiceDoctorShareScreen({
    super.key,
    required this.serviceId,
    required this.serviceName,
    required this.serviceCost,
  });

  @override
  State<ServiceDoctorShareScreen> createState() =>
      _ServiceDoctorShareScreenState();
}

class _ServiceDoctorShareScreenState extends State<ServiceDoctorShareScreen> {
  final _searchCtrl = TextEditingController();

  bool _busy = false;
  String? _error;

  List<Map<String, dynamic>> _shares = [];
  List<Map<String, dynamic>> _filtered = [];

  static const double _EPS = 0.0001;

  @override
  void initState() {
    super.initState();
    _loadShares();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /*────────────────── تحميل / فلترة ──────────────────*/
  Future<void> _loadShares() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final db = await DBService.instance.database;
      final sql = '''
            SELECT
            sds.id,
                    sds.serviceId,
                    sds.doctorId,
                    sds.sharePercentage,
                    sds.towerSharePercentage,
                    d.name AS doctorName,
            d.specialization AS doctorSpec
            FROM service_doctor_share sds
            JOIN doctors d ON d.id = sds.doctorId
            WHERE sds.serviceId = ?
            ORDER BY d.name COLLATE NOCASE
            ''';
      final res = await db.rawQuery(sql, [widget.serviceId]);
      setState(() {
        _shares = res;
        _filtered = List<Map<String, dynamic>>.from(res);
      });
      _applyFilter();
    } catch (e) {
      setState(() => _error = 'فشل تحميل النِّسَب: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyFilter() {
    final q = Formatters.normalizeForSearch(_searchCtrl.text);
    setState(() {
      if (q.isEmpty) {
        _filtered = List<Map<String, dynamic>>.from(_shares);
      } else {
        _filtered = _shares.where((s) {
          final n =
              Formatters.normalizeForSearch((s['doctorName'] ?? '').toString());
          final sp =
              Formatters.normalizeForSearch((s['doctorSpec'] ?? '').toString());
          return n.contains(q) || sp.contains(q);
        }).toList();
      }
    });
  }

  /*────────────────── اختيار طبيب (BottomSheet) ──────────────────*/
  Future<Doctor?> _pickDoctor() async {
    final doctors = await DBService.instance.getAllDoctors();
    final list = List<Doctor>.from(doctors);
    final search = TextEditingController();
    List<Doctor> filtered = List<Doctor>.from(list);

    return showModalBottomSheet<Doctor>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: const Icon(Icons.person_search_rounded,
                            color: kPrimaryColor, size: 18),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('اختر الطبيب',
                            style: TextStyle(
                                fontWeight: FontWeight.w900, fontSize: 16)),
                      ),
                      IconButton(
                        tooltip: 'إغلاق',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                TSearchField(
                  controller: search,
                  hint: 'ابحث باسم الطبيب أو التخصص…',
                  onChanged: (v) {
                    final q = Formatters.normalizeForSearch(v);
                    filtered = list.where((d) {
                      final name = Formatters.normalizeForSearch(d.name);
                      final spec =
                          Formatters.normalizeForSearch(d.specialization);
                      return name.contains(q) || spec.contains(q);
                    }).toList();
                    (ctx as Element).markNeedsBuild();
                  },
                  onClear: () {
                    search.clear();
                    filtered = List<Doctor>.from(list);
                    (ctx as Element).markNeedsBuild();
                  },
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final d = filtered[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: NeuCard(
                          onTap: () => Navigator.pop(ctx, d),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundColor: kPrimaryColor,
                              child:
                                  const Icon(Icons.person, color: Colors.white),
                            ),
                            title: Text('د/ ${d.name}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                            subtitle: Text(d.specialization,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: scheme.onSurface
                                        .withValues(alpha: .75))),
                            trailing: const Icon(Icons.chevron_left_rounded),
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
      },
    );
  }

  /*────────────────── إضافة/تعديل نسبة ──────────────────*/
  Future<void> _addOrEditShare({int? shareId}) async {
    final isEdit = shareId != null;
    final title = isEdit ? 'تعديل نسبة الطبيب' : 'إضافة نسبة الطبيب';

    int? selectedDoctorId;
    String? selectedDoctorName;
    double sharePercent = 0.0;
    double towerPercent = 0.0;

    if (isEdit) {
      final old =
          _shares.firstWhere((e) => e['id'] == shareId, orElse: () => {});
      selectedDoctorId = old['doctorId'] as int?;
      selectedDoctorName = (old['doctorName'] as String?) ?? '';
      sharePercent = ((old['sharePercentage'] as num?) ?? 0).toDouble();
      towerPercent = ((old['towerSharePercentage'] as num?) ?? 0).toDouble();
    }

    final shareCtrl = TextEditingController(
        text: sharePercent > 0 ? sharePercent.toString() : '');
    final towerCtrl = TextEditingController(
        text: towerPercent > 0 ? towerPercent.toString() : '');

    await showDialog(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: StatefulBuilder(
            builder: (dialogCtx, setDialog) {
              Future<void> pick() async {
                final d = await _pickDoctor();
                if (d != null) {
                  setDialog(() {
                    selectedDoctorId = d.id;
                    selectedDoctorName = d.name;
                  });
                }
              }

              String? validate() {
                final sp =
                    double.tryParse(shareCtrl.text.replaceAll(',', '.')) ?? 0;
                final tp =
                    double.tryParse(towerCtrl.text.replaceAll(',', '.')) ?? 0;
                if (sp < 0 || tp < 0) return 'النِّسب يجب أن تكون موجبة';
                if (sp == 0 && tp == 0) {
                  return 'لا يمكن أن تكون النِّسب صفرًا معًا';
                }
                if (sp + tp > 100 + _EPS) {
                  return 'مجموع النِّسب يجب أن لا يتجاوز 100%';
                }
                // منع تكرار الطبيب لنفس الخدمة عند الإضافة أو عند تغيير الطبيب
                if ((selectedDoctorId != null) &&
                    _shares.any((s) =>
                        s['doctorId'] == selectedDoctorId &&
                        s['id'] != shareId)) {
                  return 'هذا الطبيب مُسجل مسبقًا لهذه الخدمة';
                }
                return null;
              }

              return AlertDialog(
                backgroundColor: scheme.surface,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                title: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NeuCard(
                        onTap: pick,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: kPrimaryColor.withValues(alpha: .10),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.all(8),
                              child: const Icon(Icons.person_rounded,
                                  color: kPrimaryColor, size: 18),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                selectedDoctorId == null
                                    ? 'اختر الطبيب'
                                    : 'د/ $selectedDoctorName',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800),
                              ),
                            ),
                            const Icon(Icons.chevron_left_rounded),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      NeuField(
                        controller: shareCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        labelText: 'نسبة الطبيب (%)',
                        prefix: const Icon(Icons.percent_rounded),
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.center,
                        onChanged: (_) => setDialog(() {}),
                      ),
                      const SizedBox(height: 10),
                      NeuField(
                        controller: towerCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        labelText: 'نسبة المركز الطبي (%)',
                        prefix: const Icon(Icons.domain_rounded),
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.center,
                        onChanged: (_) => setDialog(() {}),
                      ),
                      const SizedBox(height: 8),
                      Builder(builder: (_) {
                        final err = validate();
                        return err == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(err,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: scheme.error,
                                        fontWeight: FontWeight.w700)),
                              );
                      }),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogCtx),
                      child: const Text('إلغاء')),
                  FilledButton(
                    onPressed: () async {
                      // تحقق القيم
                      if (!isEdit && selectedDoctorId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('الرجاء اختيار الطبيب')),
                        );
                        return;
                      }
                      final sp = double.tryParse(
                              shareCtrl.text.replaceAll(',', '.')) ??
                          0;
                      final tp = double.tryParse(
                              towerCtrl.text.replaceAll(',', '.')) ??
                          0;

                      // إعادة التحقق قبل الحفظ
                      final err = () {
                        if (sp < 0 || tp < 0) {
                          return 'النِّسب يجب أن تكون موجبة';
                        }
                        if (sp == 0 && tp == 0) {
                          return 'لا يمكن أن تكون النِّسب صفرًا معًا';
                        }
                        if (sp + tp > 100 + _EPS) {
                          return 'مجموع النِّسب يجب أن لا يتجاوز 100%';
                        }
                        if ((selectedDoctorId != null) &&
                            _shares.any((s) =>
                                s['doctorId'] == selectedDoctorId &&
                                s['id'] != shareId)) {
                          return 'هذا الطبيب مُسجل مسبقًا لهذه الخدمة';
                        }
                        return null;
                      }();

                      if (err != null) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(err)));
                        return;
                      }

                      setState(() => _busy = true);
                      try {
                        if (isEdit) {
                          await DBService.instance.updateServiceDoctorShare(
                            id: shareId,
                            sharePercentage: sp,
                            towerSharePercentage: tp,
                            // ملاحظة: إذا أردت السماح بتغيير الطبيب في التعديل
                            // أضف وسيط doctorId داخل DBService.updateServiceDoctorShare
                            // مع تعديل الاستعلام. نُبقيه ثابتًا هنا افتراضيًا.
                          );
                        } else {
                          await DBService.instance.insertServiceDoctorShare(
                            serviceId: widget.serviceId,
                            doctorId: selectedDoctorId!,
                            sharePercentage: sp,
                            towerSharePercentage: tp,
                          );
                        }
                        if (!mounted) return;
                        Navigator.pop(dialogCtx);
                        await _loadShares();
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
                    child: const Text('حفظ'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _deleteShare(int shareId) async {
    final scheme = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('تأكيد الحذف'),
        content: const Text('هل تريد حذف هذه النسبة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (confirm == true) {
      await DBService.instance.deleteServiceDoctorShare(shareId);
      await _loadShares();
    }
  }

  /*──────── مجاميع النِّسَب ────────*/
  double get _sumDoctorAll => _shares.fold<double>(
      0, (p, s) => p + (((s['sharePercentage'] as num?) ?? 0).toDouble()));
  double get _sumTowerAll => _shares.fold<double>(
      0, (p, s) => p + (((s['towerSharePercentage'] as num?) ?? 0).toDouble()));
  double get _sumAll => _sumDoctorAll + _sumTowerAll;

  String _fmtPct(double v) => v.toStringAsFixed(2);

  Widget _totalsBar(ColorScheme scheme) {
    Color dot;
    String label;
    final sum = _sumAll;

    if ((sum - 100).abs() <= 0.01) {
      dot = scheme.tertiary; // جيد
      label = 'مكتمل (100%)';
    } else if (sum < 100 - 0.01) {
      dot = Colors.orange; // ناقص
      label = 'ناقص (${_fmtPct(100 - sum)}%)';
    } else {
      dot = scheme.error; // زائد
      label = 'زائد (${_fmtPct(sum - 100)}%)';
    }

    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.all(10),
            child: const Icon(Icons.pie_chart_outline_rounded,
                color: kPrimaryColor, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'مجموع نسب الخدمة — الأطباء: ${_fmtPct(_sumDoctorAll)}% • المركز: ${_fmtPct(_sumTowerAll)}% • المجموع: ${_fmtPct(_sumAll)}%',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .95),
                fontWeight: FontWeight.w800,
                fontSize: 14.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  /*──────── جسم الصفحة ────────*/
  List<Widget> _buildBody(ColorScheme scheme) {
    if (_error != null) {
      return [
        _ErrorCard(message: _error!, onRetry: _loadShares),
      ];
    }
    if (_busy && _shares.isEmpty) {
      return const [
        SizedBox(height: 100),
        Center(child: CircularProgressIndicator()),
      ];
    }
    if (_filtered.isEmpty) {
      return const [
        SizedBox(height: 80),
        Center(child: Text('لا توجد أي نسب للأطباء بعد')),
      ];
    }

    return [
      ..._filtered.map((s) {
        final id = s['id'] as int;
        final docName = (s['doctorName'] ?? '') as String;
        final docSpec = (s['doctorSpec'] ?? '') as String;
        final pct = ((s['sharePercentage'] as num?) ?? 0).toDouble();
        final towerPct = ((s['towerSharePercentage'] as num?) ?? 0).toDouble();

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NeuCard(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: const Icon(Icons.person_outline_rounded,
                          color: kPrimaryColor, size: 18),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'د/ $docName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 16),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TInfoCard(
                        icon: Icons.badge_outlined,
                        label: 'التخصص',
                        value: docSpec.isEmpty ? '—' : docSpec,
                        maxLines: 2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TInfoCard(
                        icon: Icons.percent_rounded,
                        label: 'نسبة الطبيب',
                        value: '${pct.toStringAsFixed(2)} %',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TInfoCard(
                        icon: Icons.domain_rounded,
                        label: 'نسبة المركز',
                        value: '${towerPct.toStringAsFixed(2)} %',
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
                        onPressed: () => _addOrEditShare(shareId: id),
                      ),
                    ),
                    const SizedBox(width: 10),
                    NeuButton.flat(
                      icon: Icons.delete_outline_rounded,
                      label: 'حذف',
                      onPressed: () => _deleteShare(id),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }),
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
              onPressed: _loadShares,
            ),
          ],
        ),
        body: SafeArea(
          child: RefreshIndicator(
            color: scheme.primary,
            onRefresh: _loadShares,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: [
                /*──────── بطاقة معلومات الخدمة ────────*/
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
                        child: const Icon(Icons.medical_services_outlined,
                            color: kPrimaryColor, size: 22),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.serviceName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 16)),
                            const SizedBox(height: 4),
                            Text(
                                'السعر: ${widget.serviceCost.toStringAsFixed(2)}',
                                style: TextStyle(
                                    color:
                                        scheme.onSurface.withValues(alpha: .75),
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                /*──────── شريط التلخيص الإجمالي للنِّسَب ────────*/
                _totalsBar(scheme),

                const SizedBox(height: 12),

                /*──────── شريط البحث عن طبيب داخل القائمة ────────*/
                TSearchField(
                  controller: _searchCtrl,
                  hint: 'فلترة حسب اسم الطبيب أو التخصص…',
                  onChanged: (_) => _applyFilter(),
                  onClear: () {
                    _searchCtrl.clear();
                    _applyFilter();
                  },
                ),

                const SizedBox(height: 12),

                /*──────── زر إضافة نسبة ────────*/
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: NeuButton.primary(
                    icon: Icons.add_rounded,
                    label: 'إضافة نسبة جديدة',
                    onPressed: _busy ? null : () => _addOrEditShare(),
                  ),
                ),

                const SizedBox(height: 16),

                // المحتوى
                ..._buildBody(scheme),
              ],
            ),
          ),
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
                  color: scheme.onSurface, fontWeight: FontWeight.w700),
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
