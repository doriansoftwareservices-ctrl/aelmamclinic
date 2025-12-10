// lib/screens/repository/statistics/repository_statistics_screen.dart
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/services/repository_service.dart';
import 'package:aelmamclinic/utils/excel_export_helper.dart';

class RepositoryStatisticsScreen extends StatefulWidget {
  const RepositoryStatisticsScreen({super.key});

  static const routeName = '/repository/statistics';

  @override
  State<RepositoryStatisticsScreen> createState() =>
      _RepositoryStatisticsScreenState();
}

class _RepositoryStatisticsScreenState
    extends State<RepositoryStatisticsScreen> {
  final _q = TextEditingController();
  final Set<int> _expandedTypeIds = {};

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  /*──────────────── حسابات إحصائية لكل صنف ────────────────*/
  Future<int> _purchasedQty(Item item) async {
    final db = await RepositoryService.instance.database;
    final res = await db.rawQuery(
      'SELECT COALESCE(SUM(quantity),0) AS bought FROM purchases WHERE item_id = ?',
      [item.id],
    );
    return (res.first['bought'] as num).toInt();
  }

  Future<double> _totalPurchasedCost(Item item) async {
    final db = await RepositoryService.instance.database;
    final res = await db.rawQuery(
      'SELECT COALESCE(SUM(quantity*unit_price),0) AS total FROM purchases WHERE item_id = ?',
      [item.id],
    );
    return (res.first['total'] as num).toDouble();
  }

  /// يعيد: [المستخدم, تكلفة المشتريات]
  Future<List<num>> _loadStats(Item item) async {
    final purchased = await _purchasedQty(item);
    final remaining = item.stock;
    final used = (purchased - remaining).clamp(0, purchased);
    final cost = await _totalPurchasedCost(item);
    return [used, cost];
  }

  Future<void> _export(ItemType type, List<Item> items) async {
    try {
      final path = await ExcelExportHelper.exportItemStatistics(
        type: type,
        items: items,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تمّ حفظ الملف في:\n$path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل التصدير: $e')),
      );
    }
  }

  List<Item> _applyQuery(List<Item> items) {
    final q = _q.text.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items.where((it) => it.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final scheme = Theme.of(context).colorScheme;

    // ✅ بديل repo.items: نجمع عدد الأصناف عبر كل الفئات
    final totalItems = repo.types.fold<int>(
      0,
      (sum, t) => sum + repo.itemsOf(t.id!).length,
    );

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
        ),
        body: SafeArea(
          child: repo.types.isEmpty
              ? const Center(child: Text('لا توجد بيانات بعد.'))
              : RefreshIndicator(
                  color: scheme.primary,
                  onRefresh: () async {
                    setState(() {});
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                    children: [
                      // شريط البحث بنمط TBIAN
                      TSearchField(
                        controller: _q,
                        hint: 'ابحث باسم الصنف…',
                        onChanged: (_) => setState(() {}),
                        onClear: () {
                          _q.clear();
                          setState(() {});
                        },
                      ),
                      const SizedBox(height: 14),

                      // ملخص سريع (عدد الفئات/الأصناف)
                      Wrap(
                        spacing: 16,
                        runSpacing: 18,
                        children: [
                          _InfoBadge(
                            icon: Icons.category_outlined,
                            label: 'عدد الفئات',
                            value: '${repo.types.length}',
                          ),
                          _InfoBadge(
                            icon: Icons.inventory_2_outlined,
                            label: 'إجمالي الأصناف',
                            value: '$totalItems',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // قائمة الفئات + الأصناف
                      ...repo.types.map((type) {
                        final typeId = type.id!;
                        final allItems = repo.itemsOf(typeId);
                        final items = _applyQuery(allItems);

                        final isExpanded = _expandedTypeIds.contains(typeId);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: NeuCard(
                            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // رأس الفئة
                                ListTile(
                                  contentPadding:
                                      const EdgeInsets.symmetric(horizontal: 6),
                                  leading: Container(
                                    decoration: BoxDecoration(
                                      color:
                                          kPrimaryColor.withValues(alpha: .10),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    padding: const EdgeInsets.all(8),
                                    child: const Icon(Icons.category_outlined,
                                        color: kPrimaryColor, size: 20),
                                  ),
                                  title: Text(
                                    type.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16),
                                  ),
                                  subtitle: Text(
                                    items.isEmpty
                                        ? '— لا أصناف —'
                                        : 'عدد الأصناف: ${items.length}',
                                    style: TextStyle(
                                        color: scheme.onSurface
                                            .withValues(alpha: .75)),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TOutlinedButton(
                                        icon: Icons.download_outlined,
                                        label: 'تصدير',
                                        onPressed: allItems.isEmpty
                                            ? null
                                            : () => _export(type, allItems),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        tooltip: isExpanded ? 'طيّ' : 'توسيع',
                                        icon: Icon(isExpanded
                                            ? Icons.expand_less
                                            : Icons.expand_more),
                                        onPressed: () {
                                          setState(() {
                                            if (isExpanded) {
                                              _expandedTypeIds.remove(typeId);
                                            } else {
                                              _expandedTypeIds.add(typeId);
                                            }
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ),

                                // قائمة الأصناف
                                AnimatedCrossFade(
                                  crossFadeState: isExpanded
                                      ? CrossFadeState.showSecond
                                      : CrossFadeState.showFirst,
                                  duration: const Duration(milliseconds: 180),
                                  firstChild: const SizedBox.shrink(),
                                  secondChild: Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(6, 0, 6, 10),
                                    child: Column(
                                      children: items.isEmpty
                                          ? [
                                              Padding(
                                                padding:
                                                    const EdgeInsets.fromLTRB(
                                                        6, 0, 6, 6),
                                                child: Text(
                                                  '— لا أصناف —',
                                                  style: TextStyle(
                                                      color: scheme.onSurface
                                                          .withValues(
                                                              alpha: .7)),
                                                ),
                                              ),
                                            ]
                                          : items
                                              .map((it) => Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            bottom: 8),
                                                    child: NeuCard(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 8,
                                                          vertical: 6),
                                                      child: FutureBuilder<
                                                          List<num>>(
                                                        future: _loadStats(it),
                                                        builder: (_, snap) {
                                                          final isDone = snap
                                                                  .connectionState ==
                                                              ConnectionState
                                                                  .done;
                                                          final used =
                                                              (snap.data?[0] ??
                                                                      0)
                                                                  .toInt();
                                                          final totalCost =
                                                              (snap.data?[1] ??
                                                                      0.0)
                                                                  .toDouble();
                                                          final remaining =
                                                              it.stock;

                                                          if (!isDone &&
                                                              snap.data ==
                                                                  null) {
                                                            return ListTile(
                                                              dense: true,
                                                              contentPadding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                      horizontal:
                                                                          6),
                                                              leading:
                                                                  const SizedBox(
                                                                width: 24,
                                                                height: 24,
                                                                child: CircularProgressIndicator(
                                                                    strokeWidth:
                                                                        2.2),
                                                              ),
                                                              title: Text(
                                                                it.name,
                                                                style: const TextStyle(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w700),
                                                              ),
                                                              subtitle:
                                                                  const LinearProgressIndicator(
                                                                      minHeight:
                                                                          2),
                                                            );
                                                          }

                                                          return ListTile(
                                                            dense: true,
                                                            contentPadding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal:
                                                                        6),
                                                            leading: const Icon(
                                                                Icons
                                                                    .inventory_2_outlined,
                                                                color:
                                                                    kPrimaryColor),
                                                            title: Text(
                                                              it.name,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w800),
                                                            ),
                                                            subtitle: Text(
                                                              'المستخدم: $used  •  المتبقي: $remaining  •  تكلفة المشتريات: ${totalCost.toStringAsFixed(2)}',
                                                              style: TextStyle(
                                                                color: scheme
                                                                    .onSurface
                                                                    .withValues(
                                                                        alpha:
                                                                            .80),
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                      ),
                                                    ),
                                                  ))
                                              .toList(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/*──────────────────── ويدجت شارة/بطاقة معلومات صغيرة ────────────────────*/
class _InfoBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoBadge({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.all(14),
      child: SizedBox(
        width: 240,
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(10),
              child: Icon(icon, color: kPrimaryColor, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .85),
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                      )),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
