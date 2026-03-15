// lib/screens/repository/purchases_consumptions/new_purchase_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

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
  int? _selectedItemId;
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
          _selectedItemId = match.first.id;
          break;
        }
      }
    }
    _didInitArgs = true;
  }

  int _asInt(String v) => int.tryParse(v.trim()) ?? 0;
  double _asDouble(String v) => double.tryParse(v.trim()) ?? 0.0;

  int get _currentStock {
    if (_selectedItemId == null) return 0;
    final repo = context.read<RepositoryProvider>();
    final list = repo.itemsOf(_selectedType?.id ?? 0);
    final fresh = list.where((e) => e.id == _selectedItemId);
    if (fresh.isEmpty) return 0;
    return fresh.first.stock;
  }

  double get _totalCost {
    final q = _asInt(_qtyCtrl.text);
    final p = _asDouble(_priceCtrl.text);
    return (q > 0 && p >= 0) ? q * p : 0.0;
  }

  InputDecoration _dec(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: context.trRaw(label),
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _selectedItemId == null) return;

    setState(() => _isSaving = true);
    try {
      await context.read<RepositoryProvider>().addPurchase(
            itemId: _selectedItemId!,
            quantity: _asInt(_qtyCtrl.text),
            unitPrice: _asDouble(_priceCtrl.text),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('تم حفظ عملية الشراء بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('فشل الحفظ: $e')),
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

  List<ItemType> _dedupTypes(List<ItemType> input) {
    final byId = <int, ItemType>{};
    for (final t in input) {
      final id = t.id;
      if (id == null) continue;
      byId[id] = t;
    }
    final list = byId.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final types = _dedupTypes(repo.types);
    ItemType? selectedType;
    if (_selectedType?.id != null) {
      final match =
          types.where((t) => t.id == _selectedType!.id).toList(growable: false);
      selectedType = match.isNotEmpty ? match.first : null;
    }
    final rawItems =
        selectedType == null ? <Item>[] : repo.itemsOf(selectedType.id!);
    final seenIds = <int>{};
    final items = <Item>[];
    for (final it in rawItems) {
      final id = it.id;
      if (id == null) continue;
      if (seenIds.add(id)) items.add(it);
    }

    final predictedStock = _currentStock + _asInt(_qtyCtrl.text);
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        appBar: AppBar(
          title: const LocalizedText('إنشاء مشتريات جديدة'),
          centerTitle: true,
          elevation: 4,
          flexibleSpace: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [scheme.primaryContainer, scheme.primary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
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
          padding: kScreenPadding,
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                // نوع الصنف
                DropdownButtonFormField<ItemType>(
                  initialValue: selectedType,
                  decoration: _dec(context, 'نوع الصنف'),
                  items: types
                      .map((t) =>
                          DropdownMenuItem(value: t, child: Text(t.name)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _selectedType = v;
                    _selectedItemId = null;
                  }),
                  validator: (v) => v == null ? 'اختر نوعًا' : null,
                ),
                const SizedBox(height: 14),

                // اسم الصنف
                DropdownButtonFormField<int>(
                  initialValue: _selectedItemId != null &&
                          items.any((it) => it.id == _selectedItemId)
                      ? _selectedItemId
                      : null,
                  decoration: _dec(context, 'اسم الصنف'),
                  items: items
                      .map((it) => DropdownMenuItem(
                          value: it.id, child: Text(it.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedItemId = v),
                  validator: (v) => v == null ? 'اختر صنفًا' : null,
                ),

                if (_selectedItemId != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Row(
                          children: [
                            Icon(Icons.inventory_2_outlined,
                                size: 18, color: scheme.primary),
                            const SizedBox(width: 6),
                            LocalizedText('المخزون الحالي: $_currentStock',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: scheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Row(
                          children: [
                            Icon(Icons.trending_up,
                                size: 18, color: scheme.tertiary),
                            const SizedBox(width: 6),
                            LocalizedText('بعد الشراء: $predictedStock',
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
                        decoration: _dec(context, 'الكمية'),
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
                      backgroundColor: scheme.primaryContainer,
                      // لتوافقية أعلى مع نسخ Flutter القديمة استخدم shape بدل side
                      shape: StadiumBorder(
                        side: BorderSide(
                          color: scheme.primary.withValues(alpha: .4),
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
                  decoration: _dec(context, 'سعر الوحدة'),
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
                      : Icon(Icons.save_outlined, color: scheme.onPrimary),
                  label:
                      LocalizedText('حفظ', style: TextStyle(color: scheme.onPrimary)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: scheme.primary,
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
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Center(
            child: Icon(icon, color: scheme.onPrimary),
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: .35)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const LocalizedText('إجمالي التكلفة',
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
