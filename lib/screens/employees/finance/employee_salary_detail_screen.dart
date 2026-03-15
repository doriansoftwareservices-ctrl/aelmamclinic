// lib/screens/employees/finance/employee_salary_detail_screen.dart
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'finance_access_guard.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

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
  DateTime? _periodStart;
  DateTime? _periodEnd;

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
      await DBService.instance.repairEmployeeLoansDiscountsMissingEmployeeId();
      final emp = await DBService.instance.getEmployeeById(widget.empId);
      if (emp == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LocalizedText('الموظف غير موجود')),
        );
        Navigator.pop(context);
        return;
      }

      _employeeName = (emp['name'] ?? '').toString();
      final baseSalary = _asDouble(emp['finalSalary']);

      // نطاق الفترة الفعلية: من آخر صرف (إن وجد) إلى الآن/نهاية الشهر (أيهما أقرب)
      final monthStart = DateTime(widget.year, widget.month, 1);
      final monthEnd = DateTime(widget.year, widget.month + 1, 1)
          .subtract(const Duration(seconds: 1));
      final now = DateTime.now();
      final lastPaidAt =
          await DBService.instance.getLastSalaryPaymentDate(widget.empId);

      if (lastPaidAt != null && lastPaidAt.isAfter(monthEnd)) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _periodStart = null;
          _periodEnd = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  LocalizedText('تم صرف راتب أحدث من هذه الفترة، اختر شهرًا أحدث.')),
        );
        return;
      }

      final from = lastPaidAt == null
          ? monthStart
          : lastPaidAt.add(const Duration(seconds: 1));
      final to = now.isBefore(monthEnd) ? now : monthEnd;
      if (from.isAfter(to)) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _periodStart = null;
          _periodEnd = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LocalizedText('لا توجد فترة صالحة لهذا الشهر بعد')),
        );
        return;
      }

      // نسب ومدخلات الطبيب وحصة المركز
      final ratioSum =
          await DBService.instance.getDoctorRatioSum(widget.doctorId, from, to);
      final directInput = await DBService.instance
          .getEffectiveDoctorDirectInputSum(widget.doctorId, from, to);
      final towerShare = await DBService.instance
          .getDoctorTowerShareSum(widget.doctorId, from, to);

      // سلف وخصومات الشهر
      final loans = await DBService.instance.getEmployeeLoansSumBetween(
        employeeId: widget.empId,
        from: from,
        to: to,
      );
      final discounts = await DBService.instance.getEmployeeDiscountsSumBetween(
        employeeId: widget.empId,
        from: from,
        to: to,
      );

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
        _periodStart = from;
        _periodEnd = to;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('فشل تحميل البيانات: $e')),
      );
    }
  }

  Future<void> _confirmSalaryPayment() async {
    if (_periodStart == null || _periodEnd == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('الفترة غير صالحة لصرف الراتب')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          title: const LocalizedText('تأكيد صرف الراتب'),
          content: LocalizedText('سيتم صرف راتب $_employeeName لشهر ${widget.month}/${widget.year} '
            'بمبلغ صافي ${_fmt(_netPay)}.\n'
            'الفترة الفعلية: '
            '${_periodStart!.toLocal().toIso8601String().substring(0, 10)}'
            ' → '
            '${_periodEnd!.toLocal().toIso8601String().substring(0, 10)}\n'
            '${_netPay < 0 ? '⚠️ الصافي بالسالب! سيتم تسجيله كما هو.' : ''}',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const LocalizedText('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const LocalizedText('تأكيد'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final nowIso = DateTime.now().toIso8601String();
      final row = {
        'employeeId': widget.empId,
        'year': widget.year,
        'month': widget.month,
        'finalSalary': _finalSalary,
        'ratioSum': _ratioSum,
        'totalLoans': _totalLoans,
        'totalDiscounts': _totalDiscounts,
        'netPay': _netPay,
        'isPaid': 1,
        'paymentDate': nowIso,
        'periodStart': _periodStart!.toIso8601String(),
        'periodEnd': _periodEnd!.toIso8601String(),
      };

    try {
      final db = await DBService.instance.database;
      await db.transaction((txn) async {
        final existing = await txn.query(
          'employees_salaries',
          columns: const ['id'],
          where:
              'employeeId = ? AND year = ? AND month = ? AND ifnull(isDeleted,0)=0',
          whereArgs: [widget.empId, widget.year, widget.month],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert('employees_salaries', row);
        } else {
          await txn.update(
            'employees_salaries',
            row,
            where: 'id = ?',
            whereArgs: [existing.first['id']],
          );
        }

        await txn.rawUpdate('''
            UPDATE employees_loans
            SET isSettled = 1,
                settledAt = ?,
                leftover = 0
            WHERE employeeId = ?
              AND loanDateTime BETWEEN ? AND ?
              AND ifnull(isDeleted,0)=0
          ''', [
          nowIso,
          widget.empId,
          _periodStart!.toIso8601String(),
          _periodEnd!.toIso8601String(),
        ]);

        await txn.insert('financial_logs', {
          'transaction_type': 'Salary',
          'operation': 'pay',
          'amount': _netPay,
          'employee_id': widget.empId.toString(),
          'description':
              'صرف راتب $_employeeName لشهر ${widget.month}/${widget.year} صافي ${_fmt(_netPay)}',
          'modification_details': '',
          'timestamp': nowIso,
        });
      });
      await DBService.instance.notifyTableChanged('employees_salaries');
      await DBService.instance.notifyTableChanged('employees_loans');
      await DBService.instance.notifyTableChanged('financial_logs');

      widget.onSalaryPaid?.call(widget.empId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('تم صرف الراتب بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('فشل صرف الراتب: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subTitle = 'المستحق لشهر ${widget.month} من سنة ${widget.year}';

    return FinanceAccessGuard(
      child: Directionality(
        textDirection: Directionality.of(context),
        child: Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.account_balance_wallet_rounded),
                SizedBox(width: 8),
                LocalizedText('تفاصيل صرف الراتب'),
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
                            label: const LocalizedText('تأكيد صرف الراتب'),
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
