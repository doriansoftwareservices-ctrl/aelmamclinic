// lib/screens/employees/finance/employee_loan_create_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui show TextDirection;

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/formatters.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/logging_service.dart';

class EmployeeLoanCreateScreen extends StatefulWidget {
  final int empId;

  const EmployeeLoanCreateScreen({super.key, required this.empId});

  @override
  State<EmployeeLoanCreateScreen> createState() =>
      _EmployeeLoanCreateScreenState();
}

class _EmployeeLoanCreateScreenState extends State<EmployeeLoanCreateScreen> {
  bool _isLoading = true;

  // بيانات الموظف
  String _employeeName = '';
  double _finalSalary = 0.0;
  double _ratioSum =
      0.0; // (نسب الأشعة/المختبر + المدخلات المباشرة للطبيب إن وجد)
  double get _total => _finalSalary + _ratioSum;

  // السلفة والحسابات
  double _leftover = 0.0;

  // التاريخ/الوقت
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();

  // إدخال
  final TextEditingController _loanCtrl = TextEditingController();

  final DateFormat _dateFmt = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _loadEmployeeData();
  }

  @override
  void dispose() {
    _loanCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadEmployeeData() async {
    setState(() => _isLoading = true);

    final emp = await DBService.instance.getEmployeeById(widget.empId);
    if (emp == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لم يتم العثور على الموظف')),
      );
      Navigator.pop(context, false);
      return;
    }

    final name = (emp['name'] ?? '').toString();
    final baseSalary = (emp['finalSalary'] as num?)?.toDouble() ?? 0.0;

    double ratio = 0.0;

    // إن كان طبيبًا: اجلب doctorId المرتبط ثم احسب النِّسَب والمدخلات المباشرة لنطاق الشهر الحالي
    if ((emp['isDoctor'] as int? ?? 0) == 1) {
      final doctorId = await _resolveDoctorIdByEmployee(widget.empId);
      if (doctorId == null) {
        // لا نوقف الشاشة — فقط نعرض تنبيه خفيف، وتبقى النِّسَب = 0
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content:
                    Text('هذا الموظف محدد كطبيب لكن لا يوجد سجل طبيب مرتبط')),
          );
        }
      } else {
        final now = DateTime.now();
        final from = DateTime(now.year, now.month, 1);
        final to = DateTime(now.year, now.month + 1, 1)
            .subtract(const Duration(seconds: 1));

        final rlRatio =
            await DBService.instance.getDoctorRatioSum(doctorId, from, to);
        final docInput = await DBService.instance
            .getEffectiveDoctorDirectInputSum(doctorId, from, to);

        ratio = rlRatio + docInput;
      }
    }

    if (!mounted) return;
    setState(() {
      _employeeName = name;
      _finalSalary = baseSalary;
      _ratioSum = ratio;
      _leftover = _total; // بدايةً المتبقي = الإجمالي النظري
      _isLoading = false;
    });
  }

  Future<int?> _resolveDoctorIdByEmployee(int employeeId) async {
    final db = await DBService.instance.database;
    final res = await db.query(
      'doctors',
      where: 'employeeId = ?',
      whereArgs: [employeeId],
      limit: 1,
    );
    if (res.isEmpty) return null;
    final row = res.first;
    return (row['id'] as num).toInt();
  }

  String _formatDateTime() {
    final dateStr = _dateFmt.format(_selectedDate);
    final timeStr = _selectedTime.format(context);
    return '$dateStr  $timeStr';
  }

  Future<void> _pickDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
    );
    if (pickedTime == null) return;

    setState(() {
      _selectedDate = pickedDate;
      _selectedTime = pickedTime;
    });
  }

  double _parseAmount(String raw) {
    // تطبيع الأرقام العربية والفواصل
    final norm = Formatters.arabicToEnglishDigits(raw)
        .replaceAll('٬', '') // thousands sep
        .replaceAll(',', '.')
        .trim();
    return double.tryParse(norm) ?? 0.0;
  }

  void _onLoanAmountChanged(String val) {
    final loan = _parseAmount(val);
    setState(() {
      final left = _total - loan;
      _leftover = left < 0 ? 0 : left;
    });
  }

  Future<void> _saveLoan() async {
    final loan = _parseAmount(_loanCtrl.text);
    if (loan <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل مبلغ سلفة أكبر من صفر')),
      );
      return;
    }
    if (loan > _total + 1e-6) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'لا يمكن أن تتجاوز السلفة الإجمالي (${_total.toStringAsFixed(2)})')),
      );
      return;
    }

    final dateTime = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );

    final loanData = <String, dynamic>{
      'employeeId': widget.empId,
      'loanDateTime': dateTime.toIso8601String(),
      'finalSalary': _finalSalary,
      'ratioSum': _ratioSum,
      'loanAmount': loan,
      'leftover': (_total - loan).clamp(0, double.infinity),
    };

    try {
      await DBService.instance.insertEmployeeLoan(loanData);

      LoggingService().logTransaction(
        transactionType: "Loan",
        operation: "create",
        amount: loan,
        employeeId: widget.empId,
        description: "تم إنشاء سلفة للموظف رقم ${widget.empId} بقيمة $loan",
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إنشاء السلفة بنجاح')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل إنشاء السلفة: $e')),
      );
    }
  }

  Widget _statPill(String label, String value) {
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.request_quote_rounded),
              SizedBox(width: 8),
              Text('إنشاء سلفة'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Padding(
                  padding: kScreenPadding,
                  child: ListView(
                    children: [
                      // بطاقة تعريف الموظف
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
                                Icons.person_outline_rounded,
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
                                    _employeeName.isEmpty ? '—' : _employeeName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'الرصيد النظري الحالي: ${_total.toStringAsFixed(2)}',
                                    style: TextStyle(
                                      color: cs.onSurface.withValues(alpha: .7),
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

                      // اختيار التاريخ والوقت
                      NeuCard(
                        onTap: _pickDateTime,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Container(
                            decoration: BoxDecoration(
                              color: kPrimaryColor.withValues(alpha: .10),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.all(10),
                            child: const Icon(Icons.calendar_today_rounded,
                                color: kPrimaryColor),
                          ),
                          title: const Text(
                            'تاريخ ووقت السلفة',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: Text(
                            _formatDateTime(),
                            style: TextStyle(
                              color: cs.onSurface.withValues(alpha: .65),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          trailing: const Icon(Icons.edit_calendar_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // إحصاءات سريعة
                      NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _statPill('الراتب النهائي',
                                  _finalSalary.toStringAsFixed(2)),
                              const SizedBox(width: 12),
                              _statPill('إجمالي النِّسَب',
                                  _ratioSum.toStringAsFixed(2)),
                              const SizedBox(width: 12),
                              _statPill(
                                  'الإجمالي النظري', _total.toStringAsFixed(2)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // حقول قراءة
                      _InfoRow(
                        icon: Icons.payments_outlined,
                        label: 'الراتب النهائي',
                        value: _finalSalary.toStringAsFixed(2),
                      ),
                      const SizedBox(height: 8),
                      _InfoRow(
                        icon: Icons.percent_rounded,
                        label: 'إجمالي النسب',
                        value: _ratioSum.toStringAsFixed(2),
                      ),
                      const SizedBox(height: 8),
                      _InfoRow(
                        icon: Icons.summarize_outlined,
                        label: 'إجمالي الراتب + النسب',
                        value: _total.toStringAsFixed(2),
                      ),
                      const SizedBox(height: 12),

                      // إدخال مبلغ السلفة
                      NeuField(
                        controller: _loanCtrl,
                        hintText: 'مبلغ السلفة',
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        prefix: const Icon(Icons.request_quote_rounded),
                        onChanged: _onLoanAmountChanged,
                      ),
                      const SizedBox(height: 12),

                      // المتبقي بعد السلفة
                      _InfoRow(
                        icon: Icons.account_balance_wallet_outlined,
                        label: 'المتبقي بعد السلفة',
                        value: _leftover.toStringAsFixed(2),
                      ),
                      const SizedBox(height: 20),

                      // زر الحفظ
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saveLoan,
                          icon: const Icon(Icons.save_rounded),
                          label: const Text('حفظ'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
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
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ),
    );
  }
}
