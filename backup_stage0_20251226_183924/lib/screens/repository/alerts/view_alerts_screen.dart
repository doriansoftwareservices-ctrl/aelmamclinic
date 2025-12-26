// lib/screens/repository/alerts/view_alerts_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/alert_setting.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/services/repository_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'create_alert_screen.dart';

/// شاشة «استعراض التنبيهات» بنمط TBIAN
class ViewAlertsScreen extends StatefulWidget {
  const ViewAlertsScreen({super.key});

  static const routeName = '/repository/alerts/view';

  @override
  State<ViewAlertsScreen> createState() => _ViewAlertsScreenState();
}

class _ViewAlertsScreenState extends State<ViewAlertsScreen> {
  late Future<List<_AlertInfo>> _future;

  final _searchCtrl = TextEditingController();
  bool _showCriticalOnly = false; // المتجاوزة للحد فقط
  bool _showEnabledOnly = false; // المفعّلة فقط

  String _formatNumber(double value) {
    if ((value - value.roundToDouble()).abs() < 1e-9) {
      return value.round().toString();
    }
    var str = value.toStringAsFixed(2);
    if (str.contains('.')) {
      while (str.endsWith('0')) {
        str = str.substring(0, str.length - 1);
      }
      if (str.endsWith('.')) {
        str = str.substring(0, str.length - 1);
      }
    }
    return str;
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<List<_AlertInfo>> _load() async {
    final db = await RepositoryService.instance.database;
    final rows = await db.rawQuery('''
      SELECT a.id, a.item_id, a.threshold, a.is_enabled,
             i.name AS item_name, i.stock AS current_stock
      FROM ${AlertSetting.table} AS a
      JOIN ${Item.table} AS i ON i.id = a.item_id
      ORDER BY i.name
    ''');

    return rows
        .map((m) => _AlertInfo(
              id: m['id'] as int,
              itemName: m['item_name'] as String,
              threshold: (m['threshold'] as num).toDouble(),
              currentStock: (m['current_stock'] as num).toInt(),
              isEnabled: (m['is_enabled'] as int) == 1,
            ))
        .toList();
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    // مزامنة شريط التنبيهات العام في واجهات أخرى
    if (mounted) context.read<RepositoryProvider>().bootstrap();
  }

  Future<void> _toggleEnabled(_AlertInfo a) async {
    final db = await RepositoryService.instance.database;
    await db.update(
      AlertSetting.table,
      {'is_enabled': a.isEnabled ? 0 : 1},
      where: 'id = ?',
      whereArgs: [a.id],
    );
    await DBService.instance.notifyTableChanged(AlertSetting.table);
    await _refresh();
  }

  Future<void> _editThreshold(_AlertInfo a) async {
    final ctrl = TextEditingController(text: _formatNumber(a.threshold));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعديل العتبة'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'العدد الجديد'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ')),
        ],
      ),
    );

    if (ok == true) {
      final v = double.tryParse(ctrl.text.trim());
      if (v == null || v <= 0) return;
      final db = await RepositoryService.instance.database;
      await db.update(
        AlertSetting.table,
        {'threshold': v},
        where: 'id = ?',
        whereArgs: [a.id],
      );
      await DBService.instance.notifyTableChanged(AlertSetting.table);
      await _refresh();
    }
  }

  Future<void> _delete(_AlertInfo a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف التنبيه'),
        content: Text('حذف التنبيه للصنف "${a.itemName}"؟ لا يمكن التراجع.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final db = await RepositoryService.instance.database;
      await db.delete(AlertSetting.table, where: 'id = ?', whereArgs: [a.id]);
      await DBService.instance.notifyTableChanged(AlertSetting.table);
      await _refresh();
    }
  }

  List<_AlertInfo> _applyFilters(List<_AlertInfo> src) {
    final q = _searchCtrl.text.trim().toLowerCase();
    return src.where((a) {
      final matchesText = q.isEmpty || a.itemName.toLowerCase().contains(q);
      final isCritical = a.currentStock <= a.threshold;
      final passCritical = !_showCriticalOnly || isCritical;
      final passEnabled = !_showEnabledOnly || a.isEnabled;
      return matchesText && passCritical && passEnabled;
    }).toList();
  }

  Widget _statusChip(_AlertInfo a) {
    final critical = a.currentStock <= a.threshold;
    final color = critical ? Colors.red : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color: critical ? Colors.red.shade200 : Colors.green.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
              critical
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline,
              size: 16,
              color: color),
          const SizedBox(width: 6),
          Text(critical ? 'حرِج' : 'جيد',
              style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التنبيهات'),
          centerTitle: true,
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [scheme.primaryContainer, scheme.primary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          elevation: 4,
          actions: [
            IconButton(
              tooltip: 'إضافة تنبيه',
              icon: const Icon(Icons.add_alert_outlined),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateAlertScreen()),
                );
                await _refresh();
              },
            ),
          ],
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.surfaceContainerHigh,
                scheme.surface,
                scheme.surfaceContainerHigh
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: FutureBuilder<List<_AlertInfo>>(
            future: _future,
            builder: (_, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final original = snap.data ?? const <_AlertInfo>[];
              final data = _applyFilters(original);

              return RefreshIndicator(
                color: scheme.primary,
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                  children: [
                    // عنوان القسم
                    const TSectionHeader('إدارة التنبيهات'),

                    // شريط البحث بنمط TBIAN
                    TSearchField(
                      controller: _searchCtrl,
                      hint: 'ابحث باسم الصنف…',
                      onChanged: (_) => setState(() {}),
                      onClear: () => setState(() {}),
                    ),
                    const SizedBox(height: 10),

                    // المرشحات السريعة داخل NeuCard
                    NeuCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          FilterChip(
                            label: const Text('الحرِجة فقط'),
                            selected: _showCriticalOnly,
                            onSelected: (v) =>
                                setState(() => _showCriticalOnly = v),
                            selectedColor: Colors.red.withValues(alpha: .12),
                            checkmarkColor: Colors.red,
                          ),
                          FilterChip(
                            label: const Text('المفعَّلة فقط'),
                            selected: _showEnabledOnly,
                            onSelected: (v) =>
                                setState(() => _showEnabledOnly = v),
                            selectedColor: kPrimaryColor.withValues(alpha: .12),
                            checkmarkColor: kPrimaryColor,
                          ),
                          // زر سريع لإضافة تنبيه جديد
                          TOutlinedButton(
                            icon: Icons.add_alert_outlined,
                            label: 'تنبيه جديد',
                            onPressed: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const CreateAlertScreen()),
                              );
                              await _refresh();
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // حالات عدم وجود بيانات
                    if (original.isEmpty) ...[
                      const SizedBox(height: 80),
                      NeuCard(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: const [
                            Icon(Icons.notifications_off_outlined,
                                size: 34, color: kPrimaryColor),
                            SizedBox(height: 10),
                            Text('لا توجد تنبيهات مسجّلة.',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ] else if (data.isEmpty) ...[
                      const SizedBox(height: 80),
                      NeuCard(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: const [
                            Icon(Icons.search_off_rounded,
                                size: 34, color: kPrimaryColor),
                            SizedBox(height: 10),
                            Text('لا نتائج مطابقة للمرشّحات.',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ] else ...[
                      // القائمة
                      ...data.map((a) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: NeuCard(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 4),
                              leading: Container(
                                decoration: BoxDecoration(
                                  color: kPrimaryColor.withValues(alpha: .10),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.all(10),
                                child: const Icon(Icons.inventory_2_outlined,
                                    color: kPrimaryColor),
                              ),
                              title: Text(a.itemName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'الحد: ${_formatNumber(a.threshold)}  •  المتبقي: ${a.currentStock}',
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: .75),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    _statusChip(a),
                                  ],
                                ),
                              ),
                              trailing: PopupMenuButton<String>(
                                tooltip: 'خيارات',
                                onSelected: (val) {
                                  switch (val) {
                                    case 'toggle':
                                      _toggleEnabled(a);
                                      break;
                                    case 'edit':
                                      _editThreshold(a);
                                      break;
                                    case 'delete':
                                      _delete(a);
                                      break;
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'toggle',
                                    child: Row(
                                      children: [
                                        Icon(
                                          a.isEnabled
                                              ? Icons.notifications_off_outlined
                                              : Icons
                                                  .notifications_active_outlined,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(a.isEnabled ? 'تعطيل' : 'تفعيل'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Row(
                                      children: [
                                        Icon(Icons.tune, color: Colors.orange),
                                        SizedBox(width: 8),
                                        Text('تعديل العتبة'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete_outline,
                                            color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('حذف'),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () => _editThreshold(a),
                            ),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CreateAlertScreen()),
            );
            await _refresh();
          },
          icon: const Icon(Icons.add_alert),
          label: const Text('تنبيه جديد'),
        ),
      ),
    );
  }
}

/// نموذج داخلي لتجميع بيانات التنبيه من الاستعلام
class _AlertInfo {
  final int id;
  final String itemName;
  final double threshold;
  final int currentStock;
  final bool isEnabled;

  _AlertInfo({
    required this.id,
    required this.itemName,
    required this.threshold,
    required this.currentStock,
    required this.isEnabled,
  });
}
