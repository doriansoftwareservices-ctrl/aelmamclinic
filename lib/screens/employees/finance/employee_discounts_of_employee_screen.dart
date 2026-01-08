// lib/screens/employees/finance/employee_discounts_of_employee_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart'; // TDateButton, TOutlinedButton
import 'package:aelmamclinic/services/db_service.dart';
import 'finance_access_guard.dart';

class EmployeeDiscountsOfEmployeeScreen extends StatefulWidget {
  final int empId;
  const EmployeeDiscountsOfEmployeeScreen({super.key, required this.empId});

  @override
  State<EmployeeDiscountsOfEmployeeScreen> createState() =>
      _EmployeeDiscountsOfEmployeeScreenState();
}

class _EmployeeDiscountsOfEmployeeScreenState
    extends State<EmployeeDiscountsOfEmployeeScreen> {
  final DateFormat _dateOnly = DateFormat('yyyy-MM-dd');
  final DateFormat _dateTime = DateFormat('yyyy-MM-dd HH:mm');

  String _employeeName = '';
  List<Map<String, dynamic>> _all = [];
  List<Map<String, dynamic>> _filtered = [];

  DateTime? _startDate;
  DateTime? _endDate;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
  DateTime _endOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

  double _parseAmount(dynamic v) {
    if (v is num) return v.toDouble();
    final s =
        (v ?? '').toString().replaceAll('٬', '').replaceAll(',', '.').trim();
    return double.tryParse(s) ?? 0.0;
  }

  double get _totalFiltered =>
      _filtered.fold<double>(0.0, (sum, e) => sum + _parseAmount(e['amount']));

  Future<void> _loadData() async {
    setState(() => _loading = true);

    final emp = await DBService.instance.getEmployeeById(widget.empId);
    if (emp == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الموظف غير موجود')),
      );
      Navigator.pop(context);
      return;
    }

    final discounts =
        await DBService.instance.getDiscountsByEmployee(widget.empId);

    // فرز تنازلي بالتاريخ
    discounts.sort((a, b) {
      final da = DateTime.tryParse((a['discountDateTime'] ?? '').toString()) ??
          DateTime(1900);
      final db = DateTime.tryParse((b['discountDateTime'] ?? '').toString()) ??
          DateTime(1900);
      return db.compareTo(da);
    });

    if (!mounted) return;
    setState(() {
      _employeeName = (emp['name'] ?? '').toString();
      _all = discounts;
      _filtered = List.from(discounts);
      _loading = false;
    });
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(primary: kPrimaryColor),
        ),
        child: child!,
      ),
    );
    if (d != null) {
      setState(() => _startDate = _startOfDay(d));
      _applyFilter();
    }
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(primary: kPrimaryColor),
        ),
        child: child!,
      ),
    );
    if (d != null) {
      setState(() => _endDate = _endOfDay(d));
      _applyFilter();
    }
  }

  void _resetDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _filtered = List.from(_all);
    });
  }

  void _applyFilter() {
    if (_startDate == null && _endDate == null) {
      setState(() => _filtered = List.from(_all));
      return;
    }
    setState(() {
      _filtered = _all.where((row) {
        final dt =
            DateTime.tryParse((row['discountDateTime'] ?? '').toString());
        if (dt == null) return false;
        if (_startDate != null && dt.isBefore(_startDate!)) return false;
        if (_endDate != null && dt.isAfter(_endDate!)) return false;
        return true;
      }).toList();
    });
  }

  Future<void> _deleteDiscount(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد الحذف'),
          content: const Text('سيتم حذف الخصم نهائيًا. هل تريد المتابعة؟'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.delete_rounded),
              label: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    await DBService.instance.deleteEmployeeDiscount(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حذف الخصم بنجاح')),
    );
    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return FinanceAccessGuard(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.receipt_long_rounded),
              const SizedBox(width: 8),
              Text('خصومات $_employeeName'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loadData,
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              children: [
                // بطاقة رأس / ملخص سريع
                NeuCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(14),
                        child: const Icon(Icons.badge_rounded,
                            color: kPrimaryColor, size: 28),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _employeeName.isEmpty ? '—' : _employeeName,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // مرشحات التاريخ بنمط TBIAN
                Row(
                  children: [
                    Expanded(
                      child: TDateButton(
                        icon: Icons.calendar_month_rounded,
                        label: _startDate == null
                            ? 'من تاريخ'
                            : _dateOnly.format(_startDate!),
                        onTap: _pickStart,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TDateButton(
                        icon: Icons.event_rounded,
                        label: _endDate == null
                            ? 'إلى تاريخ'
                            : _dateOnly.format(_endDate!),
                        onTap: _pickEnd,
                      ),
                    ),
                    const SizedBox(width: 10),
                    TOutlinedButton(
                      icon: Icons.clear_all_rounded,
                      label: 'مسح',
                      onPressed: (_startDate == null && _endDate == null)
                          ? null
                          : _resetDates,
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // شريط الإحصاءات (عدد السجلات + الإجمالي)
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      _StatPill(
                        label: 'عدد السجلات',
                        value: '${_filtered.length}',
                      ),
                      const SizedBox(width: 12),
                      _StatPill(
                        label: 'إجمالي الخصومات',
                        value: _totalFiltered.toStringAsFixed(2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // القائمة + سحب للتحديث
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                          color: cs.primary,
                          onRefresh: _loadData,
                          child: _filtered.isEmpty
                              ? ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    const SizedBox(height: 120),
                                    Icon(Icons.inbox_rounded,
                                        size: 48,
                                        color: cs.onSurface
                                            .withValues(alpha: .35)),
                                    const SizedBox(height: 10),
                                    Center(
                                      child: Text(
                                        'لا توجد خصومات',
                                        style: TextStyle(
                                          color: cs.onSurface
                                              .withValues(alpha: .6),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : ListView.separated(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  itemCount: _filtered.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (ctx, i) {
                                    final row = _filtered[i];
                                    final id = (row['id'] as num).toInt();
                                    final dt = DateTime.tryParse(
                                        (row['discountDateTime'] ?? '')
                                            .toString());
                                    final amount = _parseAmount(row['amount']);
                                    final notes =
                                        (row['notes'] ?? '').toString().trim();

                                    return NeuCard(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 10),
                                      child: Row(
                                        children: [
                                          // شارة المبلغ
                                          Container(
                                            decoration: BoxDecoration(
                                              color: kPrimaryColor.withValues(
                                                  alpha: .10),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                            padding: const EdgeInsets.all(10),
                                            child: const Icon(
                                                Icons
                                                    .remove_circle_outline_rounded,
                                                color: kPrimaryColor),
                                          ),
                                          const SizedBox(width: 10),
                                          // النصوص
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        'خصم: ${amount.toStringAsFixed(2)}',
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w900,
                                                          fontSize: 15.5,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Text(
                                                      dt == null
                                                          ? '—'
                                                          : _dateTime
                                                              .format(dt),
                                                      style: TextStyle(
                                                        color: cs.onSurface
                                                            .withValues(
                                                                alpha: .65),
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 12.5,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                if (notes.isNotEmpty) ...[
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    notes,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: cs.onSurface
                                                          .withValues(
                                                              alpha: .85),
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          IconButton(
                                            tooltip: 'حذف',
                                            icon: const Icon(
                                                Icons.delete_rounded,
                                                color: Colors.red),
                                            onPressed: () =>
                                                _deleteDiscount(id),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/*──────── عناصر مساعدة صغيرة بنمط TBIAN ────────*/

class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  const _StatPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: cs.outline.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: .7),
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}
