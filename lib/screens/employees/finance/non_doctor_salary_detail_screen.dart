// lib/screens/employees/finance/non_doctor_salary_detail_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── TBIAN ─*/
import 'package:aelmamclinic/core/neumorphism.dart';

/*── الخدمات ─*/
import 'package:aelmamclinic/services/db_service.dart';
import 'finance_access_guard.dart';

/// ── ثوابت الألوان الموحدة ──
const Color accentColor = Color(0xFF004A61);
const Color lightAccentColor = Color(0xFF9ED9E6);
const Color veryLightBg = Color(0xFFF7F9F9);

class NonDoctorSalaryDetailScreen extends StatefulWidget {
  final int empId;
  final int year;
  final int month;
  final Function(int empId)? onSalaryPaid;

  const NonDoctorSalaryDetailScreen({
    super.key,
    required this.empId,
    required this.year,
    required this.month,
    this.onSalaryPaid,
  });

  @override
  State<NonDoctorSalaryDetailScreen> createState() =>
      _NonDoctorSalaryDetailScreenState();
}

class _NonDoctorSalaryDetailScreenState
    extends State<NonDoctorSalaryDetailScreen> {
  bool _isLoading = true;

  double _finalSalary = 0.0;
  double _totalLoans = 0.0;
  double _totalDiscounts = 0.0;
  double _netPay = 0.0;
  String _employeeName = '';
  DateTime? _periodStart;
  DateTime? _periodEnd;

  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? 0.0;
  }

  String _fmt(double v) => v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      await DBService.instance.repairEmployeeLoansDiscountsMissingEmployeeId();
      final emp = await DBService.instance.getEmployeeById(widget.empId);
      if (emp == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الموظف غير موجود')),
        );
        Navigator.pop(context);
        return;
      }

      final name = (emp['name'] ?? '').toString();
      final baseSalary = _toDouble(emp['finalSalary']);

      // الفترة الفعلية: من آخر صرف (إن وجد) إلى الآن/نهاية الشهر (أيهما أقرب)
      final monthStart = DateTime(widget.year, widget.month, 1);
      final monthEnd = DateTime(widget.year, widget.month + 1, 1)
          .subtract(const Duration(seconds: 1));
      final now = DateTime.now();
      final lastPaidAt =
          await DBService.instance.getLastSalaryPaymentDate(widget.empId);

      if (lastPaidAt != null && lastPaidAt.isAfter(monthEnd)) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _periodStart = null;
          _periodEnd = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('تم صرف راتب أحدث من هذه الفترة، اختر شهرًا أحدث.')),
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
          _isLoading = false;
          _periodStart = null;
          _periodEnd = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد فترة صالحة لهذا الشهر بعد')),
        );
        return;
      }
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

      final net = baseSalary - (loans + discounts);

      if (!mounted) return;
      setState(() {
        _employeeName = name;
        _finalSalary = baseSalary;
        _totalLoans = loans;
        _totalDiscounts = discounts;
        _netPay = net;
        _periodStart = from;
        _periodEnd = to;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ: $e')),
      );
      Navigator.pop(context);
    }
  }

  Future<void> _confirmSalaryPayment() async {
    if (_periodStart == null || _periodEnd == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الفترة غير صالحة لصرف الراتب')),
      );
      return;
    }
    // تأكيد قبل الصرف
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد صرف الراتب'),
          content: Text(
            'سيتم صرف راتب $_employeeName لشهر ${widget.month}/${widget.year} '
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
                child: const Text('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: accentColor),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تأكيد', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final nowIso = DateTime.now().toIso8601String();
    final data = {
      'employeeId': widget.empId,
      'year': widget.year,
      'month': widget.month,
      'finalSalary': _finalSalary,
      'ratioSum': 0.0, // توحيد الحقل مع شاشة الأطباء
      'totalLoans': _totalLoans,
      'totalDiscounts': _totalDiscounts, // متاح إن كان العمود موجودًا
      'netPay': _netPay,
      'isPaid': 1,
      'paymentDate': nowIso,
      'periodStart': _periodStart!.toIso8601String(),
      'periodEnd': _periodEnd!.toIso8601String(),
    };

    try {
      final db = await DBService.instance.database;
      await db.transaction((txn) async {
        final found = await txn.query(
          'employees_salaries',
          columns: const ['id'],
          where:
              'employeeId = ? AND year = ? AND month = ? AND ifnull(isDeleted,0)=0',
          whereArgs: [widget.empId, widget.year, widget.month],
          limit: 1,
        );

        if (found.isEmpty) {
          await txn.insert('employees_salaries', data);
        } else {
          await txn.update(
            'employees_salaries',
            data,
            where: 'id = ?',
            whereArgs: [found.first['id']],
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
    final subTitle = 'المستحق للشهر ${widget.month} من سنة ${widget.year}';

    return FinanceAccessGuard(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: const Text(
              'تفاصيل صرف الراتب (غير الأطباء)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            flexibleSpace: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [lightAccentColor, accentColor],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [veryLightBg, Colors.white, veryLightBg],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // العنوان
                      Text('دفع راتب: $_employeeName',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(subTitle),

                      const SizedBox(height: 16),

                      // بطاقة ملخّص سريعة (Neumorphism)
                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            _pill('الراتب النهائي', _fmt(_finalSalary)),
                            _pill('السلف', _fmt(_totalLoans)),
                            _pill('الخصومات', _fmt(_totalDiscounts)),
                            _pill('الصافي', _fmt(_netPay)),
                          ],
                        ),
                      ),

                      const SizedBox(height: 18),

                      // تفاصيل رقمية قابلة للقراءة فقط
                      _readOnlyField('الراتب النهائي', _fmt(_finalSalary)),
                      const SizedBox(height: 12),
                      _readOnlyField('مجموع السلف', _fmt(_totalLoans)),
                      const SizedBox(height: 12),
                      _readOnlyField('مجموع الخصومات', _fmt(_totalDiscounts)),
                      const SizedBox(height: 12),
                      _readOnlyField('الصافي', _fmt(_netPay)),

                      const SizedBox(height: 24),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accentColor,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(25)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _confirmSalaryPayment,
                          child: const Text('تأكيد صرف الراتب',
                              style: TextStyle(color: Colors.white)),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _readOnlyField(String label, String value) {
    return TextFormField(
      initialValue: value,
      readOnly: true,
      decoration: InputDecoration(
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
      ),
    );
  }

  Widget _pill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: Colors.black12.withValues(alpha: .25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
                color: Colors.black87.withValues(alpha: .7),
                fontWeight: FontWeight.w700),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}
