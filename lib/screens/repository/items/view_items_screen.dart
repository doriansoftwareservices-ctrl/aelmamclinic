// lib/screens/repository/items/view_items_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/services/repository_service.dart';

/*──────── لوحة ألوان TBIAN الموحدة ────────*/
const Color accentColor = Color(0xFF004A61);
const Color lightAccentColor = Color(0xFF9ED9E6);
const Color veryLightBg = Color(0xFFF7F9F9);

class ViewItemsScreen extends StatefulWidget {
  const ViewItemsScreen({super.key});

  static const routeName = '/repository/items/view';

  @override
  State<ViewItemsScreen> createState() => _ViewItemsScreenState();
}

class _ViewItemsScreenState extends State<ViewItemsScreen> {
  final _searchCtrl = TextEditingController();

  ItemType? _typeFilter; // نوع محدد أو الكل
  bool _showOutOfStockOnly = false; // المنتهية فقط
  String _sortKey = 'name_asc'; // name_asc | stock_asc | stock_desc

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh(RepositoryProvider repo) async {
    await repo.bootstrap();
    setState(() {});
  }

  List<Item> _applyFiltersSort(RepositoryProvider repo, List<Item> src) {
    final q = _searchCtrl.text.trim().toLowerCase();

    final filtered = src.where((it) {
      final byType = _typeFilter == null || it.typeId == _typeFilter!.id;
      final byText = q.isEmpty || it.name.toLowerCase().contains(q);
      final byStock = !_showOutOfStockOnly || (it.stock <= 0);
      return byType && byText && byStock;
    }).toList();

    switch (_sortKey) {
      case 'stock_asc':
        filtered.sort((a, b) => a.stock.compareTo(b.stock));
        break;
      case 'stock_desc':
        filtered.sort((a, b) => b.stock.compareTo(a.stock));
        break;
      default: // name_asc
        filtered.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final allItems = repo.allItems;
    final types = repo.types;

    final items = _applyFiltersSort(repo, allItems);
    final outOfStockCount = allItems.where((it) => it.stock <= 0).length;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('الأصناف المضافة',
              style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            IconButton(
              tooltip: 'إضافة صنف',
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () =>
                  Navigator.pushNamed(context, '/repository/items/add'),
            ),
          ],
          flexibleSpace: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [lightAccentColor, accentColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          elevation: 4,
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
            onRefresh: () => _refresh(repo),
            color: accentColor,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                // شريط إحصائي صغير
                _SummaryStrip(
                  totalTypes: types.length,
                  totalItems: allItems.length,
                  outOfStock: outOfStockCount,
                ),
                const SizedBox(height: 12),

                // البحث + المرشّحات + الفرز
                _FiltersBar(
                  types: types,
                  typeFilter: _typeFilter,
                  onTypeChanged: (t) => setState(() => _typeFilter = t),
                  showOutOfStockOnly: _showOutOfStockOnly,
                  onToggleOutOfStock: (v) =>
                      setState(() => _showOutOfStockOnly = v),
                  sortKey: _sortKey,
                  onSortChanged: (s) => setState(() => _sortKey = s),
                  searchCtrl: _searchCtrl,
                  onClearSearch: () => setState(() => _searchCtrl.clear()),
                ),
                const SizedBox(height: 10),

                if (allItems.isEmpty)
                  _EmptyCard(message: 'لا توجد أصناف بعد.')
                else if (items.isEmpty)
                  _EmptyCard(message: 'لا نتائج مطابقة للمرشّحات.')
                else
                  // نجمع العناصر حسب النوع بعد الفلترة
                  ..._groupByType(items, types).entries.map((entry) {
                    final type = entry.key;
                    final list = entry.value;
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                            color: lightAccentColor.withValues(alpha: .25)),
                      ),
                      child: _TypeSectionTBIAN(type: type, items: list),
                    );
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Map<ItemType, List<Item>> _groupByType(
      List<Item> items, List<ItemType> types) {
    final typeById = {for (final t in types) t.id!: t};
    final map = <ItemType, List<Item>>{};
    for (final it in items) {
      final t = typeById[it.typeId];
      if (t == null) continue;
      map.putIfAbsent(t, () => []).add(it);
    }
    // ترتيب الأقسام أبجديًا
    final sortedKeys = map.keys.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final out = <ItemType, List<Item>>{};
    for (final k in sortedKeys) {
      out[k] = map[k]!
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return out;
  }
}

/*──────────────────────── أقسام العرض ────────────────────────*/

class _TypeSectionTBIAN extends StatelessWidget {
  final ItemType type;
  final List<Item> items;

  const _TypeSectionTBIAN({required this.type, required this.items});

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      backgroundColor: Colors.white,
      collapsedBackgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      collapsedShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      leading: const CircleAvatar(
        backgroundColor: Color(0x1A9ED9E6),
        child: Icon(Icons.category_outlined, color: accentColor),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              type.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
          _Pill(text: '${items.length} صنف', color: lightAccentColor),
        ],
      ),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      children: [
        ...items.map((it) => _ItemTileTBIAN(itemId: it.id!, typeId: it.typeId)),
      ],
    );
  }
}

class _ItemTileTBIAN extends StatelessWidget {
  final int itemId;
  final int typeId;
  const _ItemTileTBIAN({required this.itemId, required this.typeId});

  Future<List<num>> _loadStats() async {
    final db = await RepositoryService.instance.database;
    final res1 = await db.rawQuery(
      'SELECT COALESCE(SUM(quantity),0) AS bought FROM purchases WHERE item_id = ?',
      [itemId],
    );
    final res2 = await db.rawQuery(
      'SELECT COALESCE(SUM(quantity*unit_price),0) AS totalCost FROM purchases WHERE item_id = ?',
      [itemId],
    );
    final boughtQty = (res1.first['bought'] as num).toInt();
    final totalCost = (res2.first['totalCost'] as num).toDouble();
    return [boughtQty, totalCost];
  }

  Future<void> _editItem(BuildContext context, Item item) async {
    final repo = context.read<RepositoryProvider>();
    final nameCtrl = TextEditingController(text: item.name);
    final priceCtrl = TextEditingController(text: item.price.toString());
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تعديل الصنف'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'الاسم'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'أدخل الاسم' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: priceCtrl,
                  decoration: const InputDecoration(labelText: 'السعر'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) => double.tryParse(v ?? '') == null
                      ? 'أدخل سعرًا صحيحًا'
                      : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: accentColor),
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: const Text('حفظ', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      await repo.updateItem(item.copyWith(
        name: nameCtrl.text.trim(),
        price: double.parse(priceCtrl.text),
      ));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تحديث الصنف')),
      );
    }
  }

  Future<void> _deleteItem(BuildContext context, Item item) async {
    final repo = context.read<RepositoryProvider>();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف الصنف'),
          content: Text('هل أنت متأكد من حذف "${item.name}"؟ لا يمكن التراجع.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    if (confirm == true) {
      await repo.deleteItem(item);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف الصنف')),
      );
    }
  }

  Future<void> _showConsumeDialog(BuildContext context, int stock) async {
    final repo = context.read<RepositoryProvider>();
    final ctrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('كمية الاستهلاك'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: 'أدخل كمية أقل من $stock'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('تأكيد')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final qty = int.tryParse(ctrl.text);
    if (qty == null || qty <= 0 || qty >= stock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('الكمية يجب أن تكون رقمًا موجبًا وأقل من $stock')),
      );
      return;
    }

    await repo.consumeItem(itemId: itemId, quantity: qty);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم خصم $qty من المخزون')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final current = repo.itemsOf(typeId).firstWhere((e) => e.id == itemId);
    final stock = current.stock;
    final critical = stock <= 0;

    return FutureBuilder<List<num>>(
      future: _loadStats(),
      builder: (_, snap) {
        final boughtQty = snap.data?[0] ?? 0;
        final totalCost = (snap.data?[1] ?? 0.0).toDouble();

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: (critical ? Colors.red : lightAccentColor)
                  .withValues(alpha: .25),
            ),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: .04),
                  blurRadius: 8,
                  offset: const Offset(0, 4)),
            ],
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: lightAccentColor.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                critical
                    ? Icons.warning_amber_outlined
                    : Icons.inventory_2_outlined,
                color: critical ? Colors.red : accentColor,
              ),
            ),
            title: Text(current.name,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'المتبقي: $stock',
                    style: TextStyle(
                      color:
                          critical ? Colors.red.shade700 : Colors.grey.shade800,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'مشتراة: $boughtQty  •  تكلفة المشتريات: ${totalCost.toStringAsFixed(2)}',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'خيارات',
              onSelected: (val) {
                switch (val) {
                  case 'edit':
                    _editItem(context, current);
                    break;
                  case 'delete':
                    _deleteItem(context, current);
                    break;
                  case 'consume':
                    _showConsumeDialog(context, stock);
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(Icons.edit, color: accentColor),
                      SizedBox(width: 8),
                      Text('تعديل'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'consume',
                  child: Row(
                    children: [
                      Icon(Icons.move_down, color: Colors.orange),
                      SizedBox(width: 8),
                      Text('إضافة استهلاك'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Colors.red),
                      SizedBox(width: 8),
                      Text('حذف'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/*──────────────────────── عناصر الواجهة المساعدة ────────────────────────*/

class _SummaryStrip extends StatelessWidget {
  final int totalTypes;
  final int totalItems;
  final int outOfStock;

  const _SummaryStrip({
    required this.totalTypes,
    required this.totalItems,
    required this.outOfStock,
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
              offset: const Offset(0, 6))
        ],
      ),
      child: Row(
        children: [
          _StatChip(
              icon: Icons.category_outlined,
              label: 'أنواع',
              value: '$totalTypes'),
          const SizedBox(width: 10),
          _StatChip(
              icon: Icons.inventory_2_outlined,
              label: 'أصناف',
              value: '$totalItems'),
          const SizedBox(width: 10),
          _StatChip(
            icon: Icons.warning_amber_rounded,
            label: 'منتهية',
            value: '$outOfStock',
            color: outOfStock > 0 ? Colors.red : Colors.green,
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  const _StatChip({
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

class _FiltersBar extends StatelessWidget {
  final List<ItemType> types;
  final ItemType? typeFilter;
  final ValueChanged<ItemType?> onTypeChanged;

  final bool showOutOfStockOnly;
  final ValueChanged<bool> onToggleOutOfStock;

  final String sortKey;
  final ValueChanged<String> onSortChanged;

  final TextEditingController searchCtrl;
  final VoidCallback onClearSearch;

  const _FiltersBar({
    required this.types,
    required this.typeFilter,
    required this.onTypeChanged,
    required this.showOutOfStockOnly,
    required this.onToggleOutOfStock,
    required this.sortKey,
    required this.onSortChanged,
    required this.searchCtrl,
    required this.onClearSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // بحث
        TextField(
          controller: searchCtrl,
          decoration: InputDecoration(
            hintText: 'ابحث باسم الصنف…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: searchCtrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear), onPressed: onClearSearch),
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(25),
                borderSide: BorderSide.none),
          ),
          onChanged: (_) => (context as Element).markNeedsBuild(),
        ),
        const SizedBox(height: 8),

        // مرشّحات سريعة + فرز
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // نوع الصنف
            _DropdownPill<ItemType?>(
              value: typeFilter,
              label: typeFilter?.name ?? 'كل الأنواع',
              items: [
                const DropdownMenuItem<ItemType?>(
                    value: null, child: Text('كل الأنواع')),
                ...types.map((t) =>
                    DropdownMenuItem<ItemType?>(value: t, child: Text(t.name))),
              ],
              onChanged: onTypeChanged,
              icon: Icons.category_outlined,
            ),
            // فرز
            _DropdownPill<String>(
              value: sortKey,
              label: _sortLabel(sortKey),
              items: const [
                DropdownMenuItem(value: 'name_asc', child: Text('الاسم (أ-ي)')),
                DropdownMenuItem(
                    value: 'stock_asc', child: Text('المخزون (تصاعدي)')),
                DropdownMenuItem(
                    value: 'stock_desc', child: Text('المخزون (تنازلي)')),
              ],
              onChanged: onSortChanged,
              icon: Icons.sort_outlined,
            ),
            // منتهية فقط
            FilterChip(
              label: const Text('المنتهية فقط'),
              selected: showOutOfStockOnly,
              onSelected: onToggleOutOfStock,
              selectedColor: Colors.red.withValues(alpha: .12),
              checkmarkColor: Colors.red,
            ),
          ],
        ),
      ],
    );
  }

  String _sortLabel(String key) {
    switch (key) {
      case 'stock_asc':
        return 'المخزون (تصاعدي)';
      case 'stock_desc':
        return 'المخزون (تنازلي)';
      default:
        return 'الاسم (أ-ي)';
    }
  }
}

class _DropdownPill<T> extends StatelessWidget {
  final T value;
  final String label;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T> onChanged;
  final IconData icon;

  const _DropdownPill({
    required this.value,
    required this.label,
    required this.items,
    required this.onChanged,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: lightAccentColor.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: DropdownButton<T>(
        value: value,
        underline: const SizedBox.shrink(),
        icon: const Icon(Icons.keyboard_arrow_down_rounded),
        onChanged: (v) {
          if (v != null || value == null) onChanged(v as T);
        },
        items: items,
        selectedItemBuilder: (_) => [
          for (final _ in items) _Pill(text: label, color: lightAccentColor)
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Text(text,
          style: TextStyle(color: accentColor, fontWeight: FontWeight.w800)),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final String message;
  const _EmptyCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 280,
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
