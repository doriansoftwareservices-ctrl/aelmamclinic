// lib/screens/consumption/new_consumption_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/logging_service.dart';
import 'list_consumption_screen.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class NewConsumptionScreen extends StatefulWidget {
  const NewConsumptionScreen({super.key});

  @override
  State<NewConsumptionScreen> createState() => _NewConsumptionScreenState();
}

class _NewConsumptionScreenState extends State<NewConsumptionScreen> {
  DateTime _selectedDate = DateTime.now();

  final TextEditingController _addTypeCtrl = TextEditingController();
  final TextEditingController _amountCtrl = TextEditingController();

  String? _selectedConsumptionType;
  List<String> _consumptionTypes = [];

  @override
  void initState() {
    super.initState();
    _loadConsumptionTypes();
  }

  Future<void> _loadConsumptionTypes() async {
    final types = await DBService.instance.getAllConsumptionTypes();
    setState(() => _consumptionTypes = types);
  }

  Future<void> _saveConsumption() async {
    if (_selectedConsumptionType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('الرجاء اختيار نوع المصروفات / الاستهلاكات')),
      );
      return;
    }
    final amount =
        double.tryParse(_amountCtrl.text.replaceAll(',', '.')) ?? 0.0;

    final record = Consumption(
      date: _selectedDate,
      amount: amount,
      note: _selectedConsumptionType!,
    );

    try {
      await DBService.instance.insertConsumption(record);
      LoggingService().logTransaction(
        transactionType: "Consumption",
        operation: "create",
        amount: amount,
        employeeId: null,
        description: "تم تسجيل عملية استهلاك لنوع $_selectedConsumptionType",
      );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ListConsumptionScreen()),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل حفظ الاستهلاك: $e')),
      );
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  void _showConsumptionTypeDialog() {
    TextEditingController searchCtrl = TextEditingController();
    List<String> filtered = List.from(_consumptionTypes);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final scheme = Theme.of(ctx).colorScheme;
          return AlertDialog(
            backgroundColor: scheme.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadius)),
            title: const Text('اختر نوع المصروفات / الاستهلاكات'),
            contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  NeuField(
                    controller: searchCtrl,
                    labelText: 'بحث',
                    prefix: const Icon(Icons.search),
                    onChanged: (q) {
                      setD(() {
                        filtered = _consumptionTypes
                            .where((t) =>
                                t.toLowerCase().contains(q.toLowerCase()))
                            .toList();
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 260,
                    child: filtered.isEmpty
                        ? const Center(child: Text('لا يوجد أنواع'))
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) => NeuCard(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              onTap: () {
                                setState(() =>
                                    _selectedConsumptionType = filtered[i]);
                                Navigator.pop(ctx);
                              },
                              child: Row(
                                children: [
                                  const Icon(Icons.checklist_rtl_rounded,
                                      color: kPrimaryColor),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      filtered[i],
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14.5),
                                    ),
                                  ),
                                  const Icon(Icons.chevron_left_rounded),
                                ],
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('إغلاق')),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);

    return Scaffold(
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
            const Text('إضافة مبلغ صرف أو استهلاك'),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: ListView(
            children: [
              // رأس لطيف
              NeuCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: const Icon(Icons.request_quote_rounded,
                          color: kPrimaryColor, size: 26),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'تسجيل عملية صرف/استهلاك',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // إضافة نوع جديد سريعًا
              Row(
                children: [
                  Expanded(
                    child: NeuField(
                      controller: _addTypeCtrl,
                      labelText: 'إضافة نوع مصروفات / استهلاكات',
                      prefix: const Icon(Icons.add_outlined),
                    ),
                  ),
                  const SizedBox(width: 10),
                  NeuButton.flat(
                    label: 'إضافة',
                    icon: Icons.save_as_outlined,
                    onPressed: () async {
                      final newType = _addTypeCtrl.text.trim();
                      if (newType.isNotEmpty &&
                          !_consumptionTypes.contains(newType)) {
                        await DBService.instance.insertConsumptionType(newType);
                        setState(() => _consumptionTypes.add(newType));
                        _addTypeCtrl.clear();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('تمت إضافة النوع')),
                        );
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // اختيار التاريخ
              NeuCard(
                onTap: _pickDate,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading:
                      const Icon(Icons.event_rounded, color: kPrimaryColor),
                  title: const Text('التاريخ',
                      style: TextStyle(
                          fontWeight: FontWeight.w900, fontSize: 14.5)),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(dateStr,
                        style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .7),
                            fontWeight: FontWeight.w700)),
                  ),
                  trailing: const Icon(Icons.edit_calendar_rounded),
                ),
              ),
              const SizedBox(height: 12),

              // المبلغ
              NeuField(
                controller: _amountCtrl,
                labelText: 'المبلغ',
                keyboardType: TextInputType.number,
                prefix: const Icon(Icons.numbers_rounded),
              ),
              const SizedBox(height: 12),

              // نوع المصروفات
              NeuCard(
                onTap: _showConsumptionTypeDialog,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading:
                      const Icon(Icons.category_outlined, color: kPrimaryColor),
                  title: const Text(
                    'نوع المصروفات / الاستهلاكات',
                    style:
                        TextStyle(fontWeight: FontWeight.w900, fontSize: 14.5),
                  ),
                  subtitle: _selectedConsumptionType == null
                      ? Text(
                          'اضغط للاختيار',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .55),
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _selectedConsumptionType!,
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: .8),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                  trailing: const Icon(Icons.chevron_left_rounded),
                ),
              ),
              const SizedBox(height: 18),

              // حفظ
              Align(
                alignment: Alignment.centerLeft,
                child: NeuButton.primary(
                  label: 'حفظ',
                  icon: Icons.check_rounded,
                  onPressed: _saveConsumption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
