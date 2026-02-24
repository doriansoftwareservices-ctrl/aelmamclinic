// lib/screens/repository/statistics/repository_statistics_screen.dart
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/services/repository_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
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
  Future<Map<int, _ItemStats>> _loadStatsMap(List<Item> items) async {
    if (items.isEmpty) return {};
    final ids = items.map((e) => e.id).whereType<int>().toList();
    if (ids.isEmpty) return {};
    final db = await RepositoryService.instance.database;

    final args1 = <Object?>[...ids];
    final in1 = ids.map((_) => '?').join(',');
    final acc1 = await DBService.instance
        .accountFilterClause(db, 'consumptions', alias: 'c', args: args1);
    final usedRows = await db.rawQuery('''
      SELECT c.itemId AS item_id, COALESCE(SUM(c.quantity),0) AS used
        FROM consumptions c
       WHERE c.itemId IN ($in1)
         AND ifnull(c.isDeleted,0)=0
         $acc1
    GROUP BY c.itemId
    ''', args1);

    final args2 = <Object?>[...ids];
    final in2 = ids.map((_) => '?').join(',');
    final acc2 = await DBService.instance
        .accountFilterClause(db, 'purchases', alias: 'p', args: args2);
    final costRows = await db.rawQuery('''
      SELECT p.item_id AS item_id, COALESCE(SUM(p.quantity*p.unit_price),0) AS total
        FROM purchases p
       WHERE p.item_id IN ($in2)
         AND ifnull(p.isDeleted,0)=0
         $acc2
    GROUP BY p.item_id
    ''', args2);

    final out = <int, _ItemStats>{};
    for (final r in usedRows) {
      final id = (r['item_id'] as num?)?.toInt();
      if (id == null) continue;
      out[id] = _ItemStats(
        usedQty: (r['used'] as num?)?.toInt() ?? 0,
        totalCost: 0.0,
      );
    }
    for (final r in costRows) {
      final id = (r['item_id'] as num?)?.toInt();
      if (id == null) continue;
      final existing = out[id];
      out[id] = _ItemStats(
        usedQty: existing?.usedQty ?? 0,
        totalCost: (r['total'] as num?)?.toDouble() ?? 0.0,
      );
    }
    return out;
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

  Widget _permissionBanner(AuthProvider auth) {
    if (auth.isOwnerOrAdmin || auth.isSuperAdmin) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.withValues(alpha: .4)),
      ),
      child: const Text(
        'تنبيه: بعض البيانات قد تكون مخفية حسب صلاحيات الحساب.',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;

    final allItems = repo.allItems;
    final totalItems = allItems.length;
    final statsFuture = _loadStatsMap(allItems);

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
          child: (repo.types.isEmpty && repo.orphanItems.isEmpty)
              ? const Center(child: Text('لا توجد بيانات بعد.'))
              : RefreshIndicator(
                  color: scheme.primary,
                  onRefresh: () async {
                    await context.read<RepositoryProvider>().bootstrap();
                    if (mounted) setState(() {});
                  },
                  child: FutureBuilder<Map<int, _ItemStats>>(
                    future: statsFuture,
                    builder: (_, snap) {
                      final stats = snap.data ?? const <int, _ItemStats>{};
                      return ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                        children: [
                          _permissionBanner(auth),
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
                              if (repo.orphanItems.isNotEmpty)
                                _InfoBadge(
                                  icon: Icons.report_gmailerrorred,
                                  label: 'أصناف بدون نوع',
                                  value: '${repo.orphanItems.length}',
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // قائمة الفئات + الأصناف
                          ...repo.types.map((type) {
                            final typeId = type.id!;
                            final allItems = repo.itemsOf(typeId);
                            final items = _applyQuery(allItems);

                            final isExpanded =
                                _expandedTypeIds.contains(typeId);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: NeuCard(
                                padding:
                                    const EdgeInsets.fromLTRB(10, 8, 10, 8),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    // رأس الفئة
                                    ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 6),
                                      leading: Container(
                                        decoration: BoxDecoration(
                                          color: kPrimaryColor.withValues(
                                              alpha: .10),
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                        padding: const EdgeInsets.all(8),
                                        child: const Icon(
                                            Icons.category_outlined,
                                            color: kPrimaryColor,
                                            size: 20),
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
                                            tooltip:
                                                isExpanded ? 'طيّ' : 'توسيع',
                                            icon: Icon(isExpanded
                                                ? Icons.expand_less
                                                : Icons.expand_more),
                                            onPressed: () {
                                              setState(() {
                                                if (isExpanded) {
                                                  _expandedTypeIds
                                                      .remove(typeId);
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
                                      duration:
                                          const Duration(milliseconds: 180),
                                      firstChild: const SizedBox.shrink(),
                                      secondChild: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            6, 0, 6, 10),
                                        child: Column(
                                          children: items.isEmpty
                                              ? [
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets
                                                            .fromLTRB(
                                                                6, 0, 6, 6),
                                                    child: Text(
                                                      '— لا أصناف —',
                                                      style: TextStyle(
                                                          color: scheme
                                                              .onSurface
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
                                                      child: _ItemStatsTile(
                                                        item: it,
                                                        stats: stats[it.id],
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
                      if (repo.orphanItems.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        NeuCard(
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ListTile(
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                leading: Container(
                                  decoration: BoxDecoration(
                                    color: kPrimaryColor.withValues(alpha: .10),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  padding: const EdgeInsets.all(8),
                                  child: const Icon(
                                    Icons.report_gmailerrorred,
                                    color: kPrimaryColor,
                                    size: 20,
                                  ),
                                ),
                                title: const Text(
                                  'أصناف بدون نوع',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16),
                                ),
                                subtitle: Text(
                                  'عدد الأصناف: ${repo.orphanItems.length}',
                                  style: TextStyle(
                                      color: scheme.onSurface
                                          .withValues(alpha: .75)),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(6, 0, 6, 10),
                                child: Column(
                                  children: _applyQuery(repo.orphanItems)
                                      .map((it) => Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 8),
                                            child: NeuCard(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 6),
                                              child: _ItemStatsTile(
                                                item: it,
                                                stats: stats[it.id],
                                              ),
                                            ),
                                          ))
                                      .toList(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                        ],
                      );
                    },
                  ),
                ),
        ),
      ),
    );
  }
}

class _ItemStatsTile extends StatelessWidget {
  final Item item;
  final _ItemStats? stats;

  const _ItemStatsTile({required this.item, required this.stats});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final used = stats?.usedQty ?? 0;
    final totalCost = stats?.totalCost ?? 0.0;
    final remaining = item.stock;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      leading: const Icon(Icons.inventory_2_outlined, color: kPrimaryColor),
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        'المستخدم: $used  •  المتبقي: $remaining  •  تكلفة المشتريات: ${totalCost.toStringAsFixed(2)}',
        style: TextStyle(
          color: scheme.onSurface.withValues(alpha: .80),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ItemStats {
  final int usedQty;
  final double totalCost;
  const _ItemStats({required this.usedQty, required this.totalCost});
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
