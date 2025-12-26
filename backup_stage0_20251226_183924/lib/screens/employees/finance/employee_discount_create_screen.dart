// lib/screens/employees/finance/employee_discount_create_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/formatters.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/logging_service.dart';

class EmployeeDiscountCreateScreen extends StatefulWidget {
  final int empId;
  const EmployeeDiscountCreateScreen({super.key, required this.empId});

  @override
  State<EmployeeDiscountCreateScreen> createState() =>
      _EmployeeDiscountCreateScreenState();
}

class _EmployeeDiscountCreateScreenState
    extends State<EmployeeDiscountCreateScreen> {
  final _formKey = GlobalKey<FormState>();

  // تاريخ ووقت عملية الخصم (تؤثر على فترة الحساب للطبيب)
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();

  // حالة التحميل
  bool _isLoading = true;

  // خصائص الموظف
  bool _isDoctor = false;
  int? _doctorId;
  String _employeeName = '';
  double _finalSalary = 0.0;

  // مجاميع الطبيب خلال الشهر المحدّد (نِسَب + مدخلات مباشرة)
  double _ratioSum = 0.0;

  // حقل المبلغ والملاحظات
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _notesCtrl = TextEditingController();

  // ناتج/ملصقات
  double get _theoreticalTotal => _finalSalary + _ratioSum;

  // المتبقي بعد إدخال مبلغ الخصم الحالي
  double _leftover = 0.0;

  // تنسيق
  final _dateOnly = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(_onAmountChanged);
    _loadEmployeeData(); // يشمل احتساب مجاميع الطبيب للشهر الجاري
  }

  @override
  void dispose() {
    _amountCtrl.removeListener(_onAmountChanged);
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  /* ===================== تحميل البيانات ===================== */

  Future<void> _loadEmployeeData() async {
    setState(() => _isLoading = true);

    try {
      final emp = await DBService.instance.getEmployeeById(widget.empId);
      if (!mounted) return;

      if (emp == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لم يتم العثور على الموظف')),
        );
        Navigator.pop(context);
        return;
      }

      _employeeName = (emp['name'] ?? '').toString();
      _finalSalary = (emp['finalSalary'] as num?)?.toDouble() ?? 0.0;
      _isDoctor = (emp['isDoctor'] as int? ?? 0) == 1;
      _doctorId = null;
      _ratioSum = 0.0;

      if (_isDoctor) {
        _doctorId = await _resolveDoctorIdByEmployee(widget.empId);
        // حتى لو لم يوجد doctorId، نكمل الواجهة ولكن ratioSum=0
        await _recomputeDoctorMonthlyAccruals();
      }

      _recomputeLeftover(); // يحدّث المتبقي بحسب المبلغ المُدخل
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر تحميل بيانات الموظف: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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

  // حساب فترة الشهر وفق تاريخ الخصم المحدّد
  DateTime get _periodStart =>
      DateTime(_selectedDate.year, _selectedDate.month, 1);
  DateTime get _periodEnd =>
      DateTime(_selectedDate.year, _selectedDate.month + 1, 1)
          .subtract(const Duration(seconds: 1));

  Future<void> _recomputeDoctorMonthlyAccruals() async {
    if (!_isDoctor || _doctorId == null) {
      setState(() => _ratioSum = 0.0);
      return;
    }
    try {
      final rlRatio = await DBService.instance.getDoctorRatioSum(
        _doctorId!,
        _periodStart,
        _periodEnd,
      );
      final docInput =
          await DBService.instance.getEffectiveDoctorDirectInputSum(
        _doctorId!,
        _periodStart,
        _periodEnd,
      );
      setState(() {
        _ratioSum = (rlRatio) + (docInput);
      });
    } catch (e) {
      // عدم إيقاف الشاشة؛ نعرض صفرًا وننبه
      if (!mounted) return;
      setState(() => _ratioSum = 0.0);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر احتساب مجاميع الطبيب للشهر: $e')),
      );
    } finally {
      _recomputeLeftover();
    }
  }

  /* ===================== تنسيق/تحقق أرقام ===================== */

  // دعم الأرقام العربية والفاصلة العشرية العربية
  double _parseAmount(String v) {
    // 1) تحويل الأرقام العربية إلى لاتينية
    var s = Formatters.arabicToEnglishDigits(v);
    // 2) إزالة فواصل الآلاف العربية/اللاتينية
    s = s.replaceAll('٬', '').replaceAll(',', '');
    // 3) دعم النقطة فقط كفاصل عشري (إن وُجد)
    // إذا أراد المستخدم الفاصلة كعشري، سيتم حذفها بالأعلى ونتعامل مع النقطة فقط
    return double.tryParse(s.trim()) ?? 0.0;
  }

  void _onAmountChanged() {
    _recomputeLeftover();
  }

  void _recomputeLeftover() {
    final discount = _parseAmount(_amountCtrl.text);
    final left = _theoreticalTotal - discount;
    setState(() {
      _leftover = left;
    });
  }

  /* ===================== اختيار التاريخ/الوقت ===================== */

  String _formatDateTime() {
    final d = _dateOnly.format(_selectedDate);
    final t = _selectedTime.format(context);
    return '$d  $t';
  }

  Future<void> _pickDateTime() async {
    final scheme = Theme.of(context).colorScheme;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: scheme.copyWith(primary: kPrimaryColor),
        ),
        child: child!,
      ),
    );
    if (pickedDate == null) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: scheme.copyWith(primary: kPrimaryColor),
        ),
        child: child!,
      ),
    );
    if (pickedTime == null) return;

    setState(() {
      _selectedDate = pickedDate;
      _selectedTime = pickedTime;
    });

    // عند تغيير التاريخ، نعيد حساب مجاميع الطبيب لهذا الشهر
    await _recomputeDoctorMonthlyAccruals();
  }

  /* ===================== الحفظ ===================== */

  Future<void> _saveDiscount() async {
    if (!_formKey.currentState!.validate()) return;

    final discount = _parseAmount(_amountCtrl.text);
    final maxAllowed = _theoreticalTotal;

    if (discount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل مبلغ الخصم أكبر من صفر')),
      );
      return;
    }
    if (discount > maxAllowed + 1e-9) {
      // منع خصم يتجاوز المتاح النظري (بهوامش عائمة طفيفة)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'مبلغ الخصم (${discount.toStringAsFixed(2)}) يتجاوز المتاح (${maxAllowed.toStringAsFixed(2)}).',
          ),
        ),
      );
      return;
    }

    final dt = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );

    final data = <String, dynamic>{
      'employeeId': widget.empId,
      'discountDateTime': dt.toIso8601String(),
      'amount': discount,
      'notes': _notesCtrl.text.trim(),
    };

    try {
      await DBService.instance.insertEmployeeDiscount(data);

      LoggingService().logTransaction(
        transactionType: "Discount",
        operation: "create",
        amount: discount,
        employeeId: widget.empId,
        description:
            "تم إنشاء خصم للموظف رقم ${widget.empId}، مبلغ: ${discount.toStringAsFixed(2)}",
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إنشاء الخصم بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل إنشاء الخصم: $e')),
      );
    }
  }

  /* ===================== واجهة المستخدم ===================== */

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final overBudget =
        _parseAmount(_amountCtrl.text) - _theoreticalTotal > 1e-9;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.receipt_long_rounded),
              SizedBox(width: 8),
              Text('إنشاء خصم'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Padding(
                  padding: kScreenPadding,
                  child: Form(
                    key: _formKey,
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
                                      _employeeName.isEmpty
                                          ? '—'
                                          : _employeeName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _isDoctor
                                          ? (_doctorId == null
                                              ? 'طبيب (بدون سجل طبيب مرتبط)'
                                              : 'طبيب (ID: $_doctorId)')
                                          : 'غير طبيب',
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

                        // إحصاءات سريعة
                        NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _statPill('الشهر',
                                    '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}'),
                                const SizedBox(width: 12),
                                _statPill('الراتب النهائي',
                                    _finalSalary.toStringAsFixed(2)),
                                const SizedBox(width: 12),
                                _statPill('إجمالي النِّسَب',
                                    _ratioSum.toStringAsFixed(2)),
                                const SizedBox(width: 12),
                                _statPill('الإجمالي النظري',
                                    _theoreticalTotal.toStringAsFixed(2)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // اختيار التاريخ والوقت (يؤثر على فترة الشهر)
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
                              child: const Icon(Icons.calendar_month_rounded,
                                  color: kPrimaryColor),
                            ),
                            title: const Text(
                              'تاريخ ووقت الخصم',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                            subtitle: Text(
                              _formatDateTime(),
                              style: TextStyle(
                                color: cs.onSurface.withValues(alpha: .7),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: const Icon(Icons.edit_calendar_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // مبلغ الخصم (مع تحقق)
                        NeuField(
                          controller: _amountCtrl,
                          hintText: 'مبلغ الخصم',
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          prefix: const Icon(Icons.attach_money_rounded),
                          validator: (v) {
                            final amt = _parseAmount(v ?? '');
                            if (amt <= 0) return 'أدخل مبلغًا أكبر من صفر';
                            if (amt - _theoreticalTotal > 1e-9) {
                              return 'المبلغ يتجاوز المتاح (${_theoreticalTotal.toStringAsFixed(2)})';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),

                        // الملاحظات
                        NeuField(
                          controller: _notesCtrl,
                          hintText: 'ملاحظات (سبب الخصم)',
                          maxLines: 2,
                          prefix: const Icon(Icons.notes_rounded),
                        ),
                        const SizedBox(height: 12),

                        // المتبقي بعد الخصم المُدخل
                        NeuCard(
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
                              child: const Icon(Icons.calculate_rounded,
                                  color: kPrimaryColor),
                            ),
                            title: Text(
                              'المتبقي النظري بعد الخصم',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: overBudget ? Colors.red : cs.onSurface,
                              ),
                            ),
                            subtitle: Text(
                              (_leftover < 0 ? 0.0 : _leftover)
                                  .toStringAsFixed(2),
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                color: overBudget ? Colors.red : cs.onSurface,
                              ),
                            ),
                            trailing: overBudget
                                ? const Icon(Icons.warning_amber_rounded,
                                    color: Colors.red)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 16),

                        // زر الحفظ
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _saveDiscount,
                            icon: const Icon(Icons.save_rounded),
                            label: const Text('حفظ'),
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

  Widget _statPill(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: scheme.outline.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .7),
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
