// lib/screens/patients/patient_balances_screen.dart
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/db_service.dart';

class PatientBalancesScreen extends StatefulWidget {
  const PatientBalancesScreen({super.key});

  @override
  State<PatientBalancesScreen> createState() => _PatientBalancesScreenState();
}

class _PatientBalancesScreenState extends State<PatientBalancesScreen> {
  final _search = TextEditingController();
  final _money = NumberFormat('#,##0.00');
  List<Patient> _all = [];
  List<Patient> _filtered = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await DBService.instance.getAllPatients();
    final filtered = list.where((p) => p.remaining > 0).toList();
    filtered.sort((a, b) => b.registerDate.compareTo(a.registerDate));
    if (!mounted) return;
    _all = filtered;
    _applyFilter();
    setState(() => _loading = false);
  }

  void _applyFilter() {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) {
      _filtered = List<Patient>.from(_all);
      return;
    }
    _filtered = _all.where((p) {
      final name = p.name.toLowerCase();
      final phone = p.phoneNumber.toLowerCase();
      return name.contains(q) || phone.contains(q);
    }).toList();
  }

  Future<void> _showPayDialog(Patient p) async {
    if (p.id == null) return;
    final amountCtrl =
        TextEditingController(text: p.remaining.toStringAsFixed(2));
    final noteCtrl = TextEditingController();
    bool settleAll = false;
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('تسديد مبلغ'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('المتبقي: ${p.remaining.toStringAsFixed(2)}'),
              const SizedBox(height: 8),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ المدفوع'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)'),
              ),
              const SizedBox(height: 8),
              StatefulBuilder(
                builder: (ctx2, setState) => CheckboxListTile(
                  value: settleAll,
                  onChanged: (v) {
                    setState(() => settleAll = v ?? false);
                    if (settleAll) {
                      amountCtrl.text = p.remaining.toStringAsFixed(2);
                    }
                  },
                  title: const Text('اعتبار المدفوع = الإجمالي'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () async {
                final raw = amountCtrl.text.trim().replaceAll(',', '.');
                final amount = double.tryParse(raw) ?? 0.0;
                if (amount <= 0 && !settleAll) return;
                try {
                  await DBService.instance.applyPatientPayment(
                    patientId: p.id!,
                    amount: amount,
                    settleAll: settleAll,
                    note: noteCtrl.text.trim().isEmpty
                        ? null
                        : noteCtrl.text.trim(),
                  );
                  if (context.mounted) Navigator.pop(ctx);
                  await _load();
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('تعذر التسديد: $e')),
                  );
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('مستحقات المرضى'),
        ),
        body: SafeArea(
          child: RefreshIndicator(
            color: scheme.primary,
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              children: [
                TSearchField(
                  controller: _search,
                  hint: 'ابحث عن اسم المريض أو رقم الهاتف',
                  onChanged: (_) {
                    setState(_applyFilter);
                  },
                  onClear: () {
                    _search.clear();
                    setState(_applyFilter);
                  },
                ),
                const SizedBox(height: 12),
                if (_loading) ...[
                  const SizedBox(height: 60),
                  const Center(child: CircularProgressIndicator()),
                ] else if (_filtered.isEmpty) ...[
                  const SizedBox(height: 60),
                  const Center(child: Text('لا توجد مستحقات حالياً.')),
                ] else ...[
                  ..._filtered.map((p) {
                    final total = p.paidAmount + p.remaining;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                p.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              subtitle: Text(
                                p.phoneNumber.isEmpty ? '—' : p.phoneNumber,
                              ),
                              trailing: TOutlinedButton(
                                icon: Icons.payments_outlined,
                                label: 'تسديد',
                                onPressed: () => _showPayDialog(p),
                              ),
                            ),
                            const Divider(height: 10),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                _statChip('الإجمالي', _money.format(total)),
                                _statChip('المدفوع', _money.format(p.paidAmount)),
                                _statChip('المتبقي', _money.format(p.remaining)),
                              ],
                            ),
                            if ((p.collateral ?? '').trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                'الرهن: ${p.collateral!.trim()}',
                                style: TextStyle(
                                  color: scheme.onSurface.withValues(alpha: .8),
                                ),
                              ),
                            ]
                          ],
                        ),
                      ),
                    );
                  }),
                ]
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPrimaryColor.withValues(alpha: .2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text(value),
        ],
      ),
    );
  }
}
