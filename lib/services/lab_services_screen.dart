// lib/screens/lab_services_screen.dart

import 'dart:io';
import 'dart:ui' as ui show TextDirection;

import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

/*── البيانات ─*/
import 'db_service.dart';

/*── شاشة نسب الأطباء لهذه الخدمة ─*/
import 'service_doctor_share_screen.dart';

class LabServicesScreen extends StatefulWidget {
  const LabServicesScreen({super.key});

  @override
  State<LabServicesScreen> createState() => _LabServicesScreenState();
}

class _LabServicesScreenState extends State<LabServicesScreen> {
  final _serviceNameCtrl = TextEditingController();
  final _serviceCostCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  bool _busy = false;
  String? _error;

  List<Map<String, dynamic>> _labServices = [];
  List<Map<String, dynamic>> _filtered = [];

  @override
  void initState() {
    super.initState();
    _loadLabServices();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _serviceNameCtrl.dispose();
    _serviceCostCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /*────────────────── Helpers (أرقام عربية/فواصل) ──────────────────*/
  String _normalizeArabicDigits(String s) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const latin = '0123456789';
    final buf = StringBuffer();
    for (final ch in s.characters) {
      final i = arabic.indexOf(ch);
      if (i >= 0) {
        buf.write(latin[i]);
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  double? _parseCost(dynamic raw) {
    if (raw == null) return null;
    var s = raw.toString().trim();
    if (s.isEmpty) return null;
    s = _normalizeArabicDigits(s).replaceAll(',', '.');
    // إزالة أي مسافات داخلية شائعة
    s = s.replaceAll(RegExp(r'\s+'), '');
    return double.tryParse(s);
  }

  String _normName(String name) =>
      _normalizeArabicDigits(name.trim().toLowerCase());

  /*────────────────── تحميل / فلترة ──────────────────*/
  Future<void> _loadLabServices() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final servicesRaw = await DBService.instance.getServicesByType('lab');
      // ننسخ ونرتّب بالاسم لتحسين العرض
      final services = List<Map<String, dynamic>>.from(servicesRaw)
        ..sort((a, b) => (a['name'] ?? '')
            .toString()
            .compareTo((b['name'] ?? '').toString()));

      setState(() {
        _labServices = services;
        _filtered = List<Map<String, dynamic>>.from(services);
      });
    } catch (e) {
      setState(() => _error = 'فشل تحميل خدمات المختبر: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filtered = List<Map<String, dynamic>>.from(_labServices);
      } else {
        _filtered = _labServices.where((e) {
          final name = (e['name'] ?? '').toString().toLowerCase();
          return name.contains(q);
        }).toList();
      }
    });
  }

  /*────────────────── إضافة/تعديل خدمة ──────────────────*/
  Future<void> _addOrEditLabService({int? serviceId}) async {
    final isEdit = serviceId != null;
    final title = isEdit ? 'تعديل خدمة المختبر' : 'إضافة خدمة مختبر';

    if (isEdit) {
      final old = _labServices.firstWhere((e) => e['id'] == serviceId,
          orElse: () => {});
      _serviceNameCtrl.text = (old['name'] as String?) ?? '';
      final num? c = (old['cost'] as num?);
      _serviceCostCtrl.text = c == null ? '' : c.toString();
    } else {
      _serviceNameCtrl.clear();
      _serviceCostCtrl.clear();
    }

    await showDialog(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: scheme.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title:
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NeuField(
                  controller: _serviceNameCtrl,
                  labelText: 'نوع الخدمة',
                  prefix: const Icon(Icons.science_outlined),
                ),
                const SizedBox(height: 10),
                NeuField(
                  controller: _serviceCostCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  labelText: 'الكلفة',
                  prefix: const Icon(Icons.attach_money_rounded),
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                final name = _serviceNameCtrl.text.trim();
                final cost = _parseCost(_serviceCostCtrl.text) ?? 0;
                if (name.isEmpty || cost <= 0) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('الرجاء إدخال بيانات صحيحة')),
                  );
                  return;
                }
                setState(() => _busy = true);
                try {
                  if (isEdit) {
                    await DBService.instance.updateMedicalService(
                      id: serviceId,
                      name: name,
                      cost: cost,
                      serviceType: 'lab',
                    );
                  } else {
                    await DBService.instance.insertMedicalService(
                      name: name,
                      cost: cost,
                      serviceType: 'lab',
                    );
                  }
                  if (!mounted) return;
                  Navigator.pop(ctx);
                  await _loadLabServices();
                } finally {
                  if (mounted) setState(() => _busy = false);
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
  }

  /*────────────────── حذف ──────────────────*/
  Future<void> _deleteLabService(int serviceId) async {
    final scheme = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('تأكيد الحذف'),
        content: const Text('هل تريد حذف هذه الخدمة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      setState(() => _busy = true);
      try {
        await DBService.instance.deleteMedicalService(serviceId);
        await _loadLabServices();
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  /*──────── استيراد/نموذج Excel (بنفس آلية add_item_screen) ────────*/
  Future<void> _importLabServicesFromExcel() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
    );
    if (picked == null || picked.files.single.path == null) return;

    if (!mounted) return;
    setState(() => _busy = true);

    try {
      // حمّل اللائحة الحالية إلى خريطة بالاسم الموحّد (lower/أرقام إنجليزية)
      final nameToRow = <String, Map<String, dynamic>>{};
      for (final e in _labServices) {
        final n = (e['name'] ?? '').toString();
        if (n.isEmpty) continue;
        nameToRow[_normName(n)] = e;
      }

      final bytes = await File(picked.files.single.path!).readAsBytes();
      final excel = xls.Excel.decodeBytes(bytes);

      int imported = 0;
      int updated = 0;
      int skipped = 0;
      final errors = <String>[];

      for (final sheetName in excel.tables.keys) {
        final sheet = excel.tables[sheetName];
        if (sheet == null) continue;

        // تخطي الصف الأول كعناوين: [نوع الخدمة, الكلفة]
        for (final row in sheet.rows.skip(1)) {
          try {
            if (row.length < 2) {
              skipped++;
              continue;
            }

            final rawName = row[0]?.value?.toString().trim();
            final rawCost = row[1]?.value;

            if (rawName == null || rawName.isEmpty) {
              skipped++;
              continue;
            }
            final cost = _parseCost(rawCost);
            if (cost == null || cost <= 0) {
              skipped++;
              continue;
            }

            final key = _normName(rawName);
            final existed = nameToRow[key];

            if (existed == null) {
              // إدراج جديد
              await DBService.instance.insertMedicalService(
                name: rawName.trim(),
                cost: cost,
                serviceType: 'lab',
              );
              imported++;
            } else {
              // تحديث السعر فقط إن تغيّر (نحتفظ بالاسم)
              final oldCost = ((existed['cost'] as num?) ?? 0).toDouble();
              if ((oldCost - cost).abs() > 1e-9) {
                await DBService.instance.updateMedicalService(
                  id: existed['id'] as int,
                  name: existed['name'] as String,
                  cost: cost,
                  serviceType: 'lab',
                );
                updated++;
              } else {
                skipped++;
              }
            }
          } catch (e) {
            errors.add(e.toString());
          }
        }
      }

      if (!mounted) return;
      await _loadLabServices();

      final msg =
          'استيراد: $imported | تحديث: $updated | تخطّي: $skipped${errors.isEmpty ? '' : ' | أخطاء: ${errors.length}'}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذّر الاستيراد: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadExcelTemplate() async {
    try {
      final excel = xls.Excel.createExcel();
      final sheet = excel['Sheet1'];

      // رؤوس الأعمدة
      sheet.appendRow(['نوع الخدمة', 'الكلفة']);
      // أمثلة
      sheet.appendRow(['فحص هيموجلوبين', '1200']);
      sheet.appendRow(['سكر تراكمي', '1500']);
      sheet.appendRow(['وظائف كبد', '2000']);

      final bytes = excel.encode()!;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/نموذج_خدمات_مختبر.xlsx');
      await file.writeAsBytes(bytes, flush: true);
      await OpenFile.open(file.path);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إنشاء وفتح نموذج Excel')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر إنشاء/فتح الملف: $e')),
      );
    }
  }

  /*──────── إحصائيات سريعة (اختياري) ────────*/
  double get _totalCost => _filtered.fold<double>(
      0.0, (s, e) => s + (((e['cost'] as num?) ?? 0).toDouble()));

  /*──────── جسم الصفحة ────────*/
  List<Widget> _buildBody(ColorScheme scheme) {
    if (_error != null) {
      return [
        _ErrorCard(message: _error!, onRetry: _loadLabServices),
      ];
    }
    if (_busy && _labServices.isEmpty) {
      return const [
        SizedBox(height: 100),
        Center(child: CircularProgressIndicator()),
      ];
    }
    if (_filtered.isEmpty) {
      return const [
        SizedBox(height: 80),
        Center(child: Text('لا توجد أي خدمات مختبر محفوظة')),
      ];
    }

    return [
      // ─── الإحصائيات السريعة ───
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(
              child: TInfoCard(
                icon: Icons.list_alt_rounded,
                label: 'عدد الخدمات',
                value: _filtered.length.toString(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TInfoCard(
                icon: Icons.summarize_rounded,
                label: 'إجمالي الأسعار',
                value: _totalCost.toStringAsFixed(2),
              ),
            ),
          ],
        ),
      ),

      // ─── قائمة الخدمات ───
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: _filtered.map((svc) {
          final id = svc['id'] as int;
          final name = (svc['name'] ?? '') as String;
          final cost = ((svc['cost'] as num?) ?? 0).toDouble();

          return SizedBox(
            width: 520,
            child: NeuCard(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    name,
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
                          value: cost.toStringAsFixed(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: NeuButton.flat(
                          icon: Icons.groups_2_rounded,
                          label: 'نِسَب الأطباء',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ServiceDoctorShareScreen(
                                  serviceId: id,
                                  serviceName: name,
                                  serviceCost: cost,
                                ),
                              ),
                            );
                          },
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
                          onPressed: () => _addOrEditLabService(serviceId: id),
                        ),
                      ),
                      const SizedBox(width: 10),
                      NeuButton.flat(
                        icon: Icons.delete_outline_rounded,
                        label: 'حذف',
                        onPressed: () => _deleteLabService(id),
                      ),
                    ],
                  ),
                ],
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
                'assets/images/logo2.png',
                height: 24,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
              const Text('ELMAM CLINIC'),
            ],
          ),
          actions: [
            // ↙️ نفس آلية add_item_screen: استيراد/نموذج من الـ AppBar
            IconButton(
              tooltip: 'استيراد من Excel',
              icon: const Icon(Icons.upload_file),
              onPressed: _busy ? null : _importLabServicesFromExcel,
            ),
            IconButton(
              tooltip: 'تحميل نموذج Excel',
              icon: const Icon(Icons.download_outlined),
              onPressed: _busy ? null : _downloadExcelTemplate,
            ),
            IconButton(
              tooltip: 'تحديث',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loadLabServices,
            ),
          ],
        ),
        body: SafeArea(
          child: RefreshIndicator(
            color: scheme.primary,
            onRefresh: _loadLabServices,
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
                        child: const Icon(Icons.science_rounded,
                            color: kPrimaryColor, size: 22),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'خدمات المختبر',
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

                /*──────── شريط البحث ────────*/
                TSearchField(
                  controller: _searchCtrl,
                  hint: 'ابحث باسم الخدمة…',
                  onChanged: (_) => _applyFilter(),
                  onClear: () {
                    _searchCtrl.clear();
                    _applyFilter();
                  },
                ),

                const SizedBox(height: 12),

                /*──────── شريط إجراءات سريع: إضافة/استيراد/نموذج ────────*/
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    NeuButton.primary(
                      icon: Icons.add_rounded,
                      label: 'إضافة خدمة مختبر',
                      onPressed: _busy ? null : () => _addOrEditLabService(),
                    ),
                    TOutlinedButton(
                      icon: Icons.upload_file,
                      label: 'استيراد Excel',
                      onPressed: _busy ? null : _importLabServicesFromExcel,
                    ),
                    TOutlinedButton(
                      icon: Icons.download_outlined,
                      label: 'نموذج Excel',
                      onPressed: _busy ? null : _downloadExcelTemplate,
                    ),
                  ],
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
