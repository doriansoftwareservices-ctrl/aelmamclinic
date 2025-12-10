// lib/screens/repository/alerts/create_alert_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';

/// شاشة «إنشاء / تعديل تنبيه قرب النفاد» بنمط TBIAN.
class CreateAlertScreen extends StatefulWidget {
  const CreateAlertScreen({super.key});

  static const routeName = '/repository/alerts/create';

  @override
  State<CreateAlertScreen> createState() => _CreateAlertScreenState();
}

class _CreateAlertScreenState extends State<CreateAlertScreen> {
  final _formKey = GlobalKey<FormState>();
  final _thresholdCtrl = TextEditingController();

  ItemType? _selectedType;
  Item? _selectedItem;
  int _currentStock = 0;
  bool _isSaving = false;

  @override
  void dispose() {
    _thresholdCtrl.dispose();
    super.dispose();
  }

  void _resetItem() {
    setState(() {
      _selectedItem = null;
      _currentStock = 0;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _selectedItem == null) return;
    setState(() => _isSaving = true);

    try {
      final threshold = double.parse(_thresholdCtrl.text.trim());
      await context.read<RepositoryProvider>().setAlert(
            itemId: _selectedItem!.id!,
            threshold: threshold,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ التنبيه بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final repo = context.watch<RepositoryProvider>();
    final types = repo.types;
    final items =
        _selectedType == null ? <Item>[] : repo.itemsOf(_selectedType!.id!);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('إنشاء تنبيه'),
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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              const TSectionHeader('تنبيه قرب النفاد'),
              const SizedBox(height: 8),

              // بطاقة تعريفية بنمط Neumorphism
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    decoration: BoxDecoration(
                      color: kPrimaryColor.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: const Icon(Icons.notifications_active_outlined,
                        color: kPrimaryColor),
                  ),
                  title: const Text(
                      'اضبط تنبيهًا يظهر عند نزول مخزون الصنف إلى حد معيّن'),
                  subtitle: Text(
                    'اختر نوع الصنف ثم الصنف، وحدّد العتبة التي عندها يتم إشعارك.',
                    style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .75)),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // النموذج
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    // نوع الصنف
                    NeuCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: DropdownButtonFormField<ItemType>(
                        value: _selectedType,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          labelText: 'نوع الصنف',
                        ),
                        items: types
                            .map((t) => DropdownMenuItem<ItemType>(
                                  value: t,
                                  child: Text(t.name),
                                ))
                            .toList(),
                        onChanged: (val) {
                          setState(() {
                            _selectedType = val;
                            _resetItem();
                          });
                        },
                        validator: (v) => v == null ? 'اختر نوعًا' : null,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // الصنف
                    NeuCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: DropdownButtonFormField<Item>(
                        value: _selectedItem,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          labelText: 'اسم الصنف',
                        ),
                        items: items
                            .map((it) => DropdownMenuItem<Item>(
                                  value: it,
                                  child: Text(it.name),
                                ))
                            .toList(),
                        onChanged: (val) {
                          setState(() {
                            _selectedItem = val;
                            _currentStock = val?.stock ?? 0;
                          });
                        },
                        validator: (v) => v == null ? 'اختر صنفًا' : null,
                      ),
                    ),

                    if (_selectedItem != null) ...[
                      const SizedBox(height: 12),
                      // عرض المخزون الحالي
                      TInfoCard(
                        icon: Icons.inventory_2_outlined,
                        label: 'المخزون الحالي',
                        value: '$_currentStock',
                      ),
                    ],

                    const SizedBox(height: 12),

                    // العتبة
                    NeuField(
                      controller: _thresholdCtrl,
                      labelText: 'العدد الذي عنده يصدر التنبيه',
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) {
                        final n = double.tryParse(v?.trim() ?? '');
                        if (n == null || n <= 0) return 'أدخل رقمًا موجبًا';
                        return null;
                      },
                      onChanged: (_) => setState(() {}),
                    ),

                    const SizedBox(height: 20),

                    // أزرار الإجراء (Primary + Outlined)
                    Row(
                      children: [
                        Expanded(
                          child: NeuButton.primary(
                            label: 'حفظ',
                            icon: _isSaving
                                ? Icons.hourglass_top_rounded
                                : Icons.save_outlined,
                            onPressed: _isSaving ? null : _submit,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TOutlinedButton(
                            icon: Icons.arrow_back_ios_new_rounded,
                            label: 'رجوع',
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
