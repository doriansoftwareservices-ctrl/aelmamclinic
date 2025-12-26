// lib/screens/repository/low_stock/low_stock_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/screens/repository/purchases_consumptions/new_purchase_screen.dart';

/*──────── لوحة ألوان TBIAN الموحدة ────────*/
const Color accentColor = Color(0xFF004A61);
const Color lightAccentColor = Color(0xFF9ED9E6);
const Color veryLightBg = Color(0xFFF7F9F9);

/// شاشة تُظهر جميع الأصناف التي وصلت/تجاوزت حدّ التنبيه.
class LowStockScreen extends StatefulWidget {
  const LowStockScreen({super.key});
  static const routeName = '/repository/low-stock';

  @override
  State<LowStockScreen> createState() => _LowStockScreenState();
}

class _LowStockScreenState extends State<LowStockScreen> {
  final _searchCtrl = TextEditingController();
  bool _criticalOnly = false; // عرض المنتهية فقط (stock <= 0)
  String _sortKey = 'stock_asc'; // name_asc | stock_asc | stock_desc

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Item> _applyFilters(List<Item> src) {
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = src.where((it) {
      final matchesText = q.isEmpty || it.name.toLowerCase().contains(q);
      final matchesCritical = !_criticalOnly || it.stock <= 0;
      return matchesText && matchesCritical;
    }).toList();

    switch (_sortKey) {
      case 'name_asc':
        filtered.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case 'stock_desc':
        filtered.sort((a, b) => b.stock.compareTo(a.stock));
        break;
      default: // stock_asc
        filtered.sort((a, b) => a.stock.compareTo(b.stock));
    }
    return filtered;
  }

  Future<void> _refresh(RepositoryProvider repo) async {
    await repo.bootstrap();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final lowItems = List<Item>.from(repo.lowStockItems);
    final criticalCount = lowItems.where((e) => e.stock <= 0).length;
    final filtered = _applyFilters(lowItems);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          elevation: 4,
          centerTitle: true,
          title: const Text('الأصناف منخفضة المخزون',
              style: TextStyle(fontWeight: FontWeight.bold)),
          flexibleSpace: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [lightAccentColor, accentColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [veryLightBg, Colors.white, veryLightBg],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: RefreshIndicator(
            color: accentColor,
            onRefresh: () => _refresh(repo),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              children: [
                // البحث
                TextField(
                  controller: _searchCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'ابحث باسم الصنف…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {});
                            },
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(25),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // شريط إحصائي + مرشِّحات
                _HeaderStats(
                  total: lowItems.length,
                  results: filtered.length,
                  critical: criticalCount,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('الحرِجة فقط'),
                      selected: _criticalOnly,
                      onSelected: (v) => setState(() => _criticalOnly = v),
                      selectedColor: Colors.red.withValues(alpha: .12),
                      checkmarkColor: Colors.red,
                    ),
                    _SortDropdown(
                      value: _sortKey,
                      onChanged: (v) => setState(() => _sortKey = v),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                if (lowItems.isEmpty)
                  _EmptyCard(message: 'لا أصناف منخفضة حاليًا.')
                else if (filtered.isEmpty)
                  _EmptyCard(message: 'لا نتائج مطابقة لمرشّحاتك.')
                else
                  ...filtered.map((it) => _ItemCard(item: it)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/*──────────────────────── عناصر الواجهة ────────────────────────*/

class _HeaderStats extends StatelessWidget {
  final int total;
  final int results;
  final int critical;

  const _HeaderStats({
    required this.total,
    required this.results,
    required this.critical,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: lightAccentColor.withValues(alpha: .35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .06),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          _StatPill(
              icon: Icons.list_alt_outlined, label: 'المجموع', value: '$total'),
          const SizedBox(width: 10),
          _StatPill(
              icon: Icons.search_outlined, label: 'النتائج', value: '$results'),
          const SizedBox(width: 10),
          _StatPill(
            icon: Icons.warning_amber_rounded,
            label: 'حرِجة',
            value: '$critical',
            color: critical > 0 ? Colors.red : Colors.green,
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  const _StatPill({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? accentColor;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: c.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.withValues(alpha: .25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: c),
            const SizedBox(width: 6),
            Text('$label: ',
                style: TextStyle(color: c, fontWeight: FontWeight.w800)),
            Text(value,
                style: TextStyle(color: c, fontWeight: FontWeight.w900)),
          ],
        ),
      ),
    );
  }
}

class _SortDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _SortDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: lightAccentColor.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: DropdownButton<String>(
        value: value,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.keyboard_arrow_down_rounded),
        items: const [
          DropdownMenuItem(value: 'stock_asc', child: Text('المخزون (تصاعدي)')),
          DropdownMenuItem(
              value: 'stock_desc', child: Text('المخزون (تنازلي)')),
          DropdownMenuItem(value: 'name_asc', child: Text('الاسم (أ-ي)')),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final String message;
  const _EmptyCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 240,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: lightAccentColor.withValues(alpha: .35)),
      ),
      child: Text(message, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

class _ItemCard extends StatelessWidget {
  final Item item;
  const _ItemCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final critical = (item.stock <= 0);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (critical ? Colors.red : Colors.orange).withValues(alpha: .25),
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: .05),
              blurRadius: 8,
              offset: const Offset(0, 4)),
        ],
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        leading: CircleAvatar(
          backgroundColor:
              (critical ? Colors.red : Colors.orange).withValues(alpha: .12),
          child: Icon(
            critical ? Icons.error_outline : Icons.warning_amber_outlined,
            color: critical ? Colors.red : Colors.orange,
          ),
        ),
        title: Text(item.name,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'المتبقي: ${item.stock}',
            style: TextStyle(
              color: critical ? Colors.red.shade700 : Colors.grey.shade800,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        trailing: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: accentColor,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          icon: const Icon(Icons.add_shopping_cart_outlined,
              color: Colors.white, size: 18),
          label: const Text('شراء', style: TextStyle(color: Colors.white)),
          onPressed: () {
            Navigator.pushNamed(
              context,
              NewPurchaseScreen.routeName,
              arguments: {'initialItemId': item.id},
            );
          },
        ),
      ),
    );
  }
}
