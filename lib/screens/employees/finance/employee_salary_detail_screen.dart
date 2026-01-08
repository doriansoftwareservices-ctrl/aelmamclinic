// lib/screens/employees/finance/employee_salary_detail_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/logging_service.dart';
import 'finance_access_guard.dart';

class EmployeeSalaryDetailScreen extends StatefulWidget {
  final int empId;
  final int doctorId;
  final int year;
  final int month;
  final Function(int empId)? onSalaryPaid;

  const EmployeeSalaryDetailScreen({
    super.key,
    required this.empId,
    required this.doctorId,
    required this.year,
    required this.month,
    this.onSalaryPaid,
  });

  @override
  State<EmployeeSalaryDetailScreen> createState() =>
      _EmployeeSalaryDetailScreenState();
}

class _EmployeeSalaryDetailScreenState
    extends State<EmployeeSalaryDetailScreen> {
  bool _loading = true;

  String _employeeName = '';
  double _finalSalary = 0.0;
  double _ratioSum = 0.0; // نسب (أشعة/مختبر)
  double _doctorInput = 0.0; // مدخلات الطبيب (بعد خصم نسبة المركز)
  double _towerShareSum = 0.0; // حصة المركز (للعرض فقط)
  double _totalLoans = 0.0;
  double _totalDiscounts = 0.0;
  double _netPay = 0.0;

  double _asDouble(dynamic v) =>
      (v is num) ? v.toDouble() : double.tryParse('$v') ?? 0.0;
  String _fmt(double v) => v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final emp = await DBService.instance.getEmployeeById(widget.empId);
      if (emp == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الموظف غير موجود')),
        );
        Navigator.pop(context);
        return;
      }

      _employeeName = (emp['name'] ?? '').toString();
      final baseSalary = _asDouble(emp['finalSalary']);

      // نطاق الشهر
      final from = DateTime(widget.year, widget.month, 1);
      final to = DateTime(widget.year, widget.month + 1, 1)
          .subtract(const Duration(seconds: 1));

      // نسب ومدخلات الطبيب وحصة المركز
      final ratioSum =
          await DBService.instance.getDoctorRatioSum(widget.doctorId, from, to);
      final directInput = await DBService.instance
          .getEffectiveDoctorDirectInputSum(widget.doctorId, from, to);
      final towerShare = await DBService.instance
          .getDoctorTowerShareSum(widget.doctorId, from, to);

      // سلف الشهر
      double loans = 0.0;
      for (final ln in await DBService.instance.getAllEmployeeLoans()) {
        if (ln['employeeId'] == widget.empId) {
          final dt = DateTime.tryParse((ln['loanDateTime'] ?? '').toString());
          if (dt != null &&
              dt.year == widget.year &&
              dt.month == widget.month) {
            loans += _asDouble(ln['loanAmount']);
          }
        }
      }

      // خصومات الشهر
      double discounts = 0.0;
      for (final ds in await DBService.instance.getAllEmployeeDiscounts()) {
        if (ds['employeeId'] == widget.empId) {
          final dt =
              DateTime.tryParse((ds['discountDateTime'] ?? '').toString());
          if (dt != null &&
              dt.year == widget.year &&
              dt.month == widget.month) {
            discounts += _asDouble(ds['amount']);
          }
        }
      }

      final net = (baseSalary + ratioSum + directInput) - (loans + discounts);

      if (!mounted) return;
      setState(() {
        _finalSalary = baseSalary;
        _ratioSum = ratioSum;
        _doctorInput = directInput;
        _towerShareSum = towerShare;
        _totalLoans = loans;
        _totalDiscounts = discounts;
        _netPay = net;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل تحميل البيانات: $e')),
      );
    }
  }

  Future<void> _confirmSalaryPayment() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد صرف الراتب'),
          content: Text(
            'سيتم صرف راتب $_employeeName لشهر ${widget.month}/${widget.year} '
            'بمبلغ صافي ${_fmt(_netPay)}.\n'
            '${_netPay < 0 ? '⚠️ الصافي بالسالب! سيتم تسجيله كما هو.' : ''}',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تأكيد'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final row = {
      'employeeId': widget.empId,
      'year': widget.year,
      'month': widget.month,
      'finalSalary': _finalSalary,
      'ratioSum': _ratioSum,
      'totalLoans': _totalLoans,
      'netPay': _netPay,
      'isPaid': 1,
      'paymentDate': DateTime.now().toIso8601String(),
    };

    try {
      final salaries = await DBService.instance.getAllEmployeeSalaries();
      final existing = salaries.firstWhere(
        (s) =>
            s['employeeId'] == widget.empId &&
            s['year'] == widget.year &&
            s['month'] == widget.month,
        orElse: () => {},
      );

      if (existing.isEmpty) {
        await DBService.instance.insertEmployeeSalary(row);
      } else {
        await DBService.instance.updateEmployeeSalary(existing['id'], row);
      }

      // علِّم سُلف هذا الشهر مسدّدة
      await DBService.instance.markEmployeeLoansSettled(
        employeeId: widget.empId,
        year: widget.year,
        month: widget.month,
      );

      // تسجيل العملية
      LoggingService().logTransaction(
        transactionType: "Salary",
        operation: "pay",
        amount: _netPay,
        employeeId: widget.empId,
        description:
            "صرف راتب $_employeeName لشهر ${widget.month}/${widget.year} صافي ${_fmt(_netPay)}",
      );

      widget.onSalaryPaid?.call(widget.empId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم صرف الراتب بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل صرف الراتب: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subTitle = 'المستحق لشهر ${widget.month} من سنة ${widget.year}';

    return FinanceAccessGuard(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.account_balance_wallet_rounded),
                SizedBox(width: 8),
                Text('تفاصيل صرف الراتب'),
              ],
            ),
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  child: Padding(
                    padding: kScreenPadding,
                    child: ListView(
                      children: [
                        // بطاقة رأس: الموظف + الشهر
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
                                child: const Icon(
                                  Icons.badge_rounded,
                                  color: kPrimaryColor,
                                  size: 28,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _employeeName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      subTitle,
                                      style: TextStyle(
                                        color:
                                            cs.onSurface.withValues(alpha: .7),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),

                        // شريط إحصاءات سريع (أفقي)
                        NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _StatPill(
                                    label: 'الراتب النهائي',
                                    value: _fmt(_finalSalary)),
                                const SizedBox(width: 12),
                                _StatPill(
                                    label: 'مجموع النِسَب',
                                    value: _fmt(_ratioSum)),
                                const SizedBox(width: 12),
                                _StatPill(
                                    label: 'مدخلات الطبيب',
                                    value: _fmt(_doctorInput)),
                                const SizedBox(width: 12),
                                _StatPill(
                                    label: 'السلف', value: _fmt(_totalLoans)),
                                const SizedBox(width: 12),
                                _StatPill(
                                    label: 'الخصومات',
                                    value: _fmt(_totalDiscounts)),
                                const SizedBox(width: 12),
                                _StatPill(
                                    label: 'حصة المركز',
                                    value: _fmt(_towerShareSum)),
                                const SizedBox(width: 12),
                                _StatPill(
                                  label: 'الصافي',
                                  value: _fmt(_netPay),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // تفاصيل رقمية للقراءة فقط
                        _InfoRow(
                          icon: Icons.payments_outlined,
                          label: 'الراتب النهائي',
                          value: _fmt(_finalSalary),
                        ),
                        const SizedBox(height: 8),
                        _InfoRow(
                          icon: Icons.percent_rounded,
                          label: 'مجموع النسب (أشعة/مختبر)',
                          value: _fmt(_ratioSum),
                        ),
                        const SizedBox(height: 8),
                        _InfoRow(
                          icon: Icons.local_hospital_outlined,
                          label: 'مدخلات الطبيب بعد خصم نسبة المركز',
                          value: _fmt(_doctorInput),
                        ),
                        const SizedBox(height: 8),
                        _InfoRow(
                          icon: Icons.request_quote_rounded,
                          label: 'مجموع السلف',
                          value: _fmt(_totalLoans),
                        ),
                        const SizedBox(height: 8),
                        _InfoRow(
                          icon: Icons.receipt_long_rounded,
                          label: 'مجموع الخصومات',
                          value: _fmt(_totalDiscounts),
                        ),
                        const SizedBox(height: 8),
                        _InfoRow(
                          icon: Icons.account_balance_outlined,
                          label: 'حصة المرفق الطبي (للعرض)',
                          value: _fmt(_towerShareSum),
                        ),
                        const SizedBox(height: 8),
                        _InfoRow(
                          icon: Icons.summarize_outlined,
                          label: 'الصافي',
                          value: _fmt(_netPay),
                          emphasize: true,
                          valueColor: _netPay < 0 ? Colors.red : cs.onSurface,
                        ),

                        const SizedBox(height: 18),

                        // زر التأكيد
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _confirmSalaryPayment,
                            icon: const Icon(Icons.check_circle_rounded),
                            label: const Text('تأكيد صرف الراتب'),
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

/*──────── عناصر واجهة مساعدة بنمط TBIAN ────────*/

class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  const _StatPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: .25),
        ),
      ),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              color:
                  Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool emphasize;
  final Color? valueColor;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.emphasize = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: kPrimaryColor),
        ),
        title: Text(
          label,
          style: TextStyle(
            color: scheme.onSurface.withValues(alpha: .75),
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            value,
            style: TextStyle(
              color: valueColor ?? scheme.onSurface,
              fontWeight: emphasize ? FontWeight.w900 : FontWeight.w800,
              fontSize: emphasize ? 16 : 14,
            ),
          ),
        ),
      ),
    );
  }
}
