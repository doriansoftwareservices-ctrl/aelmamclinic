// lib/screens/employees/finance/create_salary_payment_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/logging_service.dart';
import 'employee_salary_detail_screen.dart';
import 'non_doctor_salary_detail_screen.dart';

class CreateSalaryPaymentScreen extends StatefulWidget {
  const CreateSalaryPaymentScreen({super.key});

  @override
  State<CreateSalaryPaymentScreen> createState() =>
      _CreateSalaryPaymentScreenState();
}

class _CreateSalaryPaymentScreenState extends State<CreateSalaryPaymentScreen> {
  int? _selectedYear;
  int? _selectedMonth;

  // جميع الموظفين بحسب التصنيف
  List<Map<String, dynamic>> _doctors = [];
  List<Map<String, dynamic>> _nonDoctors = [];

  // بعد الفلترة بالبحث
  List<Map<String, dynamic>> _filteredDoctors = [];
  List<Map<String, dynamic>> _filteredNonDoctors = [];

  // حالة صرف الراتب لكل موظف في (العام/الشهر) المحددين
  final Map<int, bool> _paymentStatusMap = {};

  final _searchCtrl = TextEditingController();

  bool _isLoading = false;

  late final List<int> _years;
  late final List<int> _months;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _years = List.generate(5, (i) => (now.year - 1) + i);
    _months = List.generate(12, (i) => i + 1);
    _selectedYear = now.year;
    _selectedMonth = now.month;

    _searchCtrl.addListener(_applyFilter);
    _loadDataForSalary();
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_applyFilter);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final totalCount = _doctors.length + _nonDoctors.length;
    final paidCount = _paymentStatusMap.entries.where((e) => e.value).length;
    final unpaidCount = totalCount - paidCount;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
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
              const Text('ELMAM CLINIC'),
            ],
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // شريط خيارات العام/الشهر + أزرار تنقّل شهرية + زر عرض
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      // السابق
                      NeuButton.flat(
                        label: 'السابق',
                        icon: Icons.chevron_right_rounded,
                        onPressed: _isLoading ? null : () => _shiftMonth(-1),
                      ),
                      const SizedBox(width: 8),
                      // العام
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _selectedYear,
                          decoration: const InputDecoration(
                            labelText: 'العام',
                            border: InputBorder.none,
                          ),
                          items: _years
                              .map((y) =>
                                  DropdownMenuItem(value: y, child: Text('$y')))
                              .toList(),
                          onChanged: _isLoading
                              ? null
                              : (v) => setState(() => _selectedYear = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // الشهر
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _selectedMonth,
                          decoration: const InputDecoration(
                            labelText: 'الشهر',
                            border: InputBorder.none,
                          ),
                          items: _months
                              .map((m) =>
                                  DropdownMenuItem(value: m, child: Text('$m')))
                              .toList(),
                          onChanged: _isLoading
                              ? null
                              : (v) => setState(() => _selectedMonth = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // التالي
                      NeuButton.flat(
                        label: 'التالي',
                        icon: Icons.chevron_left_rounded,
                        onPressed: _isLoading ? null : () => _shiftMonth(1),
                      ),
                      const SizedBox(width: 12),
                      NeuButton.primary(
                        label: 'عرض',
                        icon: Icons.play_arrow_rounded,
                        onPressed: _isLoading ? null : _loadDataForSalary,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                // شريط البحث
                TSearchField(
                  controller: _searchCtrl,
                  hint: 'ابحث بالاسم…',
                  onChanged: (_) => _applyFilter(),
                  onClear: () {
                    _searchCtrl.clear();
                    _applyFilter();
                  },
                ),
                const SizedBox(height: 12),

                // لمحة إحصائية صغيرة
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _miniStatChip(
                      icon: Icons.calendar_today_rounded,
                      label: 'الفترة',
                      value: _fmtYearMonth(),
                    ),
                    _miniStatChip(
                      icon: Icons.group_rounded,
                      label: 'عدد الموظفين',
                      value: '$totalCount',
                    ),
                    _miniStatChip(
                      icon: Icons.check_circle_rounded,
                      label: 'تم الصرف',
                      value: '$paidCount',
                      valueColor: Colors.green,
                    ),
                    _miniStatChip(
                      icon: Icons.cancel_rounded,
                      label: 'لم يُصرف',
                      value: '$unpaidCount',
                      valueColor: Colors.redAccent,
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // النتائج
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                          color: cs.primary,
                          onRefresh: _loadDataForSalary,
                          child: (_filteredDoctors.isEmpty &&
                                  _filteredNonDoctors.isEmpty)
                              ? ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    const SizedBox(height: 120),
                                    Center(
                                      child: Text(
                                        'لا توجد نتائج',
                                        style: TextStyle(
                                          color: cs.onSurface
                                              .withValues(alpha: .6),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : ListView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  children: [
                                    if (_filteredDoctors.isNotEmpty) ...[
                                      _sectionHeader('الأطباء'),
                                      const SizedBox(height: 8),
                                      ..._filteredDoctors
                                          .map(_buildEmployeeTile),
                                      const SizedBox(height: 12),
                                    ],
                                    if (_filteredNonDoctors.isNotEmpty) ...[
                                      _sectionHeader('غير الأطباء'),
                                      const SizedBox(height: 8),
                                      ..._filteredNonDoctors
                                          .map(_buildEmployeeTile),
                                      const SizedBox(height: 8),
                                    ],
                                    const SizedBox(height: 60),
                                  ],
                                ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /* ===================== واجهة مساعدة ===================== */

  Widget _miniStatChip({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: kPrimaryColor, size: 18),
          ),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: valueColor ?? Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(8),
            child: const Icon(Icons.group_rounded, color: kPrimaryColor),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  Widget _buildEmployeeTile(Map<String, dynamic> emp) {
    final empId = emp['id'] as int;
    final name = (emp['name'] ?? '').toString();
    final isPaid = _paymentStatusMap[empId] ?? false;
    final isDoc = (emp['isDoctor'] ?? 0) == 1;

    return NeuCard(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      onTap: () => _onEmployeeTap(empId, isPaid, emp),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          decoration: BoxDecoration(
            color: (isPaid ? Colors.green : Colors.redAccent)
                .withValues(alpha: .12),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(10),
          child: Icon(
            isPaid ? Icons.check_circle_rounded : Icons.cancel_rounded,
            color: isPaid ? Colors.green : Colors.redAccent,
          ),
        ),
        title: Text(
          name.isEmpty ? '—' : name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          isPaid
              ? 'تم صرف الراتب لـ ${_fmtYearMonth()}'
              : 'لم يتم صرف الراتب لـ ${_fmtYearMonth()}',
          style: TextStyle(
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: Icon(
          isDoc
              ? Icons.medical_information_rounded
              : Icons.person_outline_rounded,
          color: kPrimaryColor,
        ),
      ),
    );
  }

  /* ===================== منطق وتحميل بيانات ===================== */

  Future<void> _loadDataForSalary() async {
    if (_selectedYear == null || _selectedMonth == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء اختيار العام والشهر أولاً')),
      );
      return;
    }
    setState(() => _isLoading = true);

    try {
      final allEmps = await DBService.instance.getAllEmployees();
      final salaries = await DBService.instance.getAllEmployeeSalaries();

      // تحديث خريطة حالة الدفع لكل موظف
      _paymentStatusMap.clear();

      for (final emp in allEmps) {
        final eid = (emp['id'] as num).toInt();
        final rec = salaries.firstWhere(
          (s) =>
              s['employeeId'] == eid &&
              s['year'] == _selectedYear &&
              s['month'] == _selectedMonth,
          orElse: () => const {},
        );
        final paid = rec.isNotEmpty && (rec['isPaid'] ?? 0) == 1;
        _paymentStatusMap[eid] = paid;
      }

      // تقسيم القوائم + فرز: غير المصروف أولًا ثم أبجديًا
      int sortCmp(Map<String, dynamic> a, Map<String, dynamic> b) {
        final aPaid = _paymentStatusMap[(a['id'] as num).toInt()] ?? false;
        final bPaid = _paymentStatusMap[(b['id'] as num).toInt()] ?? false;
        if (aPaid != bPaid) return aPaid ? 1 : -1; // غير المصروف أولًا
        final an = (a['name'] ?? '').toString();
        final bn = (b['name'] ?? '').toString();
        return an.toLowerCase().compareTo(bn.toLowerCase());
      }

      final docs = allEmps.where((e) => (e['isDoctor'] ?? 0) == 1).toList()
        ..sort(sortCmp);
      final nonDocs = allEmps.where((e) => (e['isDoctor'] ?? 0) == 0).toList()
        ..sort(sortCmp);

      setState(() {
        _doctors = docs;
        _nonDoctors = nonDocs;
      });

      _applyFilter();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر تحميل البيانات: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _onEmployeeTap(
      int empId, bool isPaid, Map<String, dynamic> emp) async {
    if (isPaid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم صرف الراتب مسبقاً')),
      );
      return;
    }
    if (_selectedYear == null || _selectedMonth == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء اختيار العام والشهر')),
      );
      return;
    }

    final isDoc = (emp['isDoctor'] ?? 0) == 1;

    if (isDoc) {
      final doctorId =
          await _resolveDoctorIdByEmployee((emp['id'] as num).toInt());
      if (doctorId == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('هذا الموظف محدد كطبيب، لكن لا يوجد سجل طبيب مرتبط')),
        );
        return;
      }

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EmployeeSalaryDetailScreen(
            empId: (emp['id'] as num).toInt(),
            doctorId: doctorId,
            year: _selectedYear!,
            month: _selectedMonth!,
            onSalaryPaid: _handleSalaryPaid,
          ),
        ),
      );
    } else {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NonDoctorSalaryDetailScreen(
            empId: (emp['id'] as num).toInt(),
            year: _selectedYear!,
            month: _selectedMonth!,
            onSalaryPaid: _handleSalaryPaid,
          ),
        ),
      );
    }
  }

  Future<int?> _resolveDoctorIdByEmployee(int employeeId) async {
    try {
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
    } catch (_) {
      return null;
    }
  }

  void _handleSalaryPaid(int empId) {
    setState(() => _paymentStatusMap[empId] = true);

    LoggingService().logTransaction(
      transactionType: "Salary",
      operation: "create",
      amount: 0.0,
      employeeId: empId,
      description: "تم صرف الراتب للموظف رقم $empId",
    );
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    bool match(Map<String, dynamic> e) {
      if (q.isEmpty) return true;
      final name = (e['name'] ?? '').toString().toLowerCase();
      return name.contains(q);
    }

    setState(() {
      _filteredDoctors = _doctors.where(match).toList();
      _filteredNonDoctors = _nonDoctors.where(match).toList();
    });
  }

  void _shiftMonth(int delta) {
    // delta: -1 للشهر السابق، +1 للشهر التالي
    if (_selectedYear == null || _selectedMonth == null) return;
    var y = _selectedYear!;
    var m = _selectedMonth! + delta;
    if (m < 1) {
      m = 12;
      y -= 1;
    } else if (m > 12) {
      m = 1;
      y += 1;
    }
    setState(() {
      _selectedYear = y;
      _selectedMonth = m;
    });
    _loadDataForSalary();
  }

  String _fmtYearMonth() =>
      '${_selectedYear ?? '—'}-${(_selectedMonth ?? 0).toString().padLeft(2, '0')}';
}
