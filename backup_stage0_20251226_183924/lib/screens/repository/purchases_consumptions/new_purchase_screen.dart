// lib/screens/repository/purchases_consumptions/new_purchase_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';

/*──────── ألوان TBIAN الموحدة ────────*/
const Color accentColor = Color(0xFF004A61);
const Color lightAccentColor = Color(0xFF9ED9E6);
const Color veryLightBg = Color(0xFFF7F9F9);

class NewPurchaseScreen extends StatefulWidget {
  const NewPurchaseScreen({super.key});

  // نفس المسار المستخدم في بقية الشاشات
  static const routeName = '/repository/pc/new';

  @override
  State<NewPurchaseScreen> createState() => _NewPurchaseScreenState();
}

class _NewPurchaseScreenState extends State<NewPurchaseScreen> {
  final _formKey = GlobalKey<FormState>();
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();

  ItemType? _selectedType;
  Item? _selectedItem;
  bool _isSaving = false;
  bool _didInitArgs = false;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInitArgs) return;

    // دعم التهيئة المسبقة للصنف (قادمًا من شاشة منخفض المخزون)
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic> && args['initialItemId'] != null) {
      final initialId = args['initialItemId'] as int;
      final repo = context.read<RepositoryProvider>();
      for (final t in repo.types) {
        final items = repo.itemsOf(t.id!);
        final match = items.where((it) => it.id == initialId);
        if (match.length == 1) {
          _selectedType = t;
          _selectedItem = match.first;
          break;
        }
      }
    }
    _didInitArgs = true;
  }

  int _asInt(String v) => int.tryParse(v.trim()) ?? 0;
  double _asDouble(String v) => double.tryParse(v.trim()) ?? 0.0;

  int get _currentStock {
    if (_selectedItem == null) return 0;
    final repo = context.read<RepositoryProvider>();
    final fresh = repo
        .itemsOf(_selectedItem!.typeId)
        .firstWhere((e) => e.id == _selectedItem!.id);
    return fresh.stock;
  }

  double get _totalCost {
    final q = _asInt(_qtyCtrl.text);
    final p = _asDouble(_priceCtrl.text);
    return (q > 0 && p >= 0) ? q * p : 0.0;
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(25),
          borderSide: const BorderSide(color: accentColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(25),
          borderSide: const BorderSide(color: accentColor, width: 2),
        ),
      );

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _selectedItem == null) return;

    setState(() => _isSaving = true);
    try {
      await context.read<RepositoryProvider>().addPurchase(
            itemId: _selectedItem!.id!,
            quantity: _asInt(_qtyCtrl.text),
            unitPrice: _asDouble(_priceCtrl.text),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ عملية الشراء بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _bumpQty(int delta) {
    final v = _asInt(_qtyCtrl.text) + delta;
    if (v < 0) return;
    setState(() => _qtyCtrl.text = v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final types = repo.types;
    final items =
        _selectedType == null ? <Item>[] : repo.itemsOf(_selectedType!.id!);

    final predictedStock = _currentStock + _asInt(_qtyCtrl.text);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('إنشاء مشتريات جديدة'),
          centerTitle: true,
          elevation: 4,
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
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                // نوع الصنف
                DropdownButtonFormField<ItemType>(
                  value: types.contains(_selectedType) ? _selectedType : null,
                  decoration: _dec('نوع الصنف'),
                  items: types
                      .map((t) =>
                          DropdownMenuItem(value: t, child: Text(t.name)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _selectedType = v;
                    _selectedItem = null;
                  }),
                  validator: (v) => v == null ? 'اختر نوعًا' : null,
                ),
                const SizedBox(height: 14),

                // اسم الصنف
                DropdownButtonFormField<Item>(
                  value: items.contains(_selectedItem) ? _selectedItem : null,
                  decoration: _dec('اسم الصنف'),
                  items: items
                      .map((it) =>
                          DropdownMenuItem(value: it, child: Text(it.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedItem = v),
                  validator: (v) => v == null ? 'اختر صنفًا' : null,
                ),

                if (_selectedItem != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: lightAccentColor.withValues(alpha: .18),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.inventory_2_outlined,
                                size: 18, color: accentColor),
                            const SizedBox(width: 6),
                            Text('المخزون الحالي: $_currentStock',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.trending_up,
                                size: 18, color: Colors.green),
                            const SizedBox(width: 6),
                            Text('بعد الشراء: $predictedStock',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 14),

                // الكمية + أزرار سريعة
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _qtyCtrl,
                        keyboardType: TextInputType.number,
                        decoration: _dec('الكمية'),
                        onChanged: (_) => setState(() {}),
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          if (n == null) return 'أدخل رقمًا صحيحًا';
                          if (n <= 0) return 'يجب أن تكون الكمية أكبر من 0';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    _SquareIconButton(
                      icon: Icons.remove,
                      onPressed: () => _bumpQty(-1),
                    ),
                    const SizedBox(width: 6),
                    _SquareIconButton(
                      icon: Icons.add,
                      onPressed: () => _bumpQty(1),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                Wrap(
                  spacing: 8,
                  children: [1, 5, 10, 20].map((n) {
                    return ActionChip(
                      label: Text('+$n'),
                      onPressed: () => _bumpQty(n),
                      backgroundColor: lightAccentColor.withValues(alpha: .18),
                      // لتوافقية أعلى مع نسخ Flutter القديمة استخدم shape بدل side
                      shape: StadiumBorder(
                        side: BorderSide(
                          color: lightAccentColor.withValues(alpha: .5),
                        ),
                      ),
                    );
                  }).toList(),
                ),

                const SizedBox(height: 14),

                // سعر الوحدة
                TextFormField(
                  controller: _priceCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: _dec('سعر الوحدة'),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final n = double.tryParse(v ?? '');
                    if (n == null) return 'أدخل سعرًا صحيحًا';
                    if (n < 0) return 'لا يمكن أن يكون السعر سالبًا';
                    return null;
                  },
                ),

                const SizedBox(height: 14),

                // إجمالي التكلفة
                _TotalCostCard(total: _totalCost),

                const SizedBox(height: 22),

                // حفظ
                ElevatedButton.icon(
                  icon: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined, color: Colors.white),
                  label:
                      const Text('حفظ', style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: _isSaving ? null : _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/*──────── Widgets مساعدة ────────*/

class _SquareIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _SquareIconButton({
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: lightAccentColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Center(
            child: Icon(icon, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _TotalCostCard extends StatelessWidget {
  final double total;
  const _TotalCostCard({required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: lightAccentColor.withValues(alpha: .18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: lightAccentColor),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('إجمالي التكلفة',
              style: TextStyle(fontWeight: FontWeight.w800)),
          Text(
            total.toStringAsFixed(2),
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
