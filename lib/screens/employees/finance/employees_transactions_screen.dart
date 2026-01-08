// lib/screens/employees/finance/employees_transactions_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/*── TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

/*── خدمات ─*/
import 'package:aelmamclinic/services/db_service.dart';
import 'finance_access_guard.dart';

class EmployeesTransactionsScreen extends StatefulWidget {
  const EmployeesTransactionsScreen({super.key});

  @override
  State<EmployeesTransactionsScreen> createState() =>
      _EmployeesTransactionsScreenState();
}

class _EmployeesTransactionsScreenState
    extends State<EmployeesTransactionsScreen> {
  // البيانات
  List<Map<String, dynamic>> _loans = [];
  List<Map<String, dynamic>> _discounts = [];
  List<Map<String, dynamic>> _salaries = [];

  // بعد الفلترة
  List<Map<String, dynamic>> _filteredLoans = [];
  List<Map<String, dynamic>> _filteredDiscounts = [];
  List<Map<String, dynamic>> _filteredSalaries = [];

  // كاش لأسماء الموظفين
  final Map<int, String> _empNames = {};

  // نطاق التاريخ
  DateTime? _startDate;
  DateTime? _endDate;

  // إظهار/إخفاء الأقسام
  bool _showLoans = true;
  bool _showDiscounts = true;
  bool _showSalaries = true;

  bool _busy = false;

  final DateFormat _dateFmt = DateFormat('yyyy-MM-dd');
  final DateFormat _dateTimeFmt = DateFormat('yyyy-MM-dd HH:mm');
  final NumberFormat _moneyFmt = NumberFormat('#,##0.00');

  double _asDouble(dynamic v) =>
      (v is num) ? v.toDouble() : double.tryParse('${v ?? 0}') ?? 0.0;

  @override
  void initState() {
    super.initState();
    _loadAllTransactions();
  }

  Future<void> _loadAllTransactions() async {
    setState(() => _busy = true);
    try {
      // أسماء الموظفين
      final employees = await DBService.instance.getAllEmployees();
      _empNames.clear();
      for (final e in employees) {
        final id = (e['id'] ?? 0) as int;
        _empNames[id] = (e['name'] ?? '—').toString();
      }

      // المعاملات
      final allLoans = await DBService.instance.getAllEmployeeLoans();
      final allDiscounts = await DBService.instance.getAllEmployeeDiscounts();
      final allSalaries = await DBService.instance.getAllEmployeeSalaries();

      setState(() {
        _loans = allLoans;
        _discounts = allDiscounts;
        _salaries = allSalaries;
        _filteredLoans = List.from(allLoans);
        _filteredDiscounts = List.from(allDiscounts);
        _filteredSalaries = List.from(allSalaries);
      });
      _applyFilter(); // لو كان هناك تاريخ محدد مسبقاً
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _startDate : _endDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(
            primary: scheme.primary,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = DateTime(picked.year, picked.month, picked.day, 0, 0, 0);
        } else {
          _endDate =
              DateTime(picked.year, picked.month, picked.day, 23, 59, 59, 999);
        }
      });
      _applyFilter();
    }
  }

  void _resetDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _applyFilter();
  }

  void _applyFilter() {
    final from = _startDate;
    final to = _endDate;

    setState(() {
      _filteredLoans = _filterList(_loans, 'loanDateTime', from, to);
      _filteredDiscounts =
          _filterList(_discounts, 'discountDateTime', from, to);
      _filteredSalaries = _filterList(_salaries, 'paymentDate', from, to);
    });
  }

  List<Map<String, dynamic>> _filterList(
    List<Map<String, dynamic>> list,
    String dateKey,
    DateTime? from,
    DateTime? to,
  ) {
    if (from == null && to == null) {
      return List<Map<String, dynamic>>.from(list);
    }
    return list.where((item) {
      final dateStr = item[dateKey]?.toString() ?? '';
      final dt = DateTime.tryParse(dateStr);
      if (dt == null) return false;
      if (from != null && dt.isBefore(from)) return false;
      if (to != null && dt.isAfter(to)) return false;
      return true;
    }).toList();
  }

  String _nameOf(int employeeId) => _empNames[employeeId] ?? '—';

  double _sumLoans(List<Map<String, dynamic>> v) =>
      v.fold(0.0, (p, e) => p + _asDouble(e['loanAmount']));

  double _sumDiscounts(List<Map<String, dynamic>> v) =>
      v.fold(0.0, (p, e) => p + _asDouble(e['amount']));

  double _sumSalaries(List<Map<String, dynamic>> v) =>
      v.fold(0.0, (p, e) => p + _asDouble(e['netPay']));

  @override
  Widget build(BuildContext context) {
    return FinanceAccessGuard(
      child: Directionality(
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
          child: RefreshIndicator(
            onRefresh: _loadAllTransactions,
            color: kPrimaryColor,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: kScreenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // شريط المرشحات بأسلوب TBIAN
                  Row(
                    children: [
                      Expanded(
                        child: TDateButton(
                          icon: Icons.calendar_month_rounded,
                          label: _startDate == null
                              ? 'من تاريخ'
                              : _dateFmt.format(_startDate!),
                          onTap: () => _pickDate(isStart: true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TDateButton(
                          icon: Icons.event_rounded,
                          label: _endDate == null
                              ? 'إلى تاريخ'
                              : _dateFmt.format(_endDate!),
                          onTap: () => _pickDate(isStart: false),
                        ),
                      ),
                      const SizedBox(width: 10),
                      TOutlinedButton(
                        icon: Icons.refresh_rounded,
                        label: 'مسح',
                        onPressed: (_startDate == null && _endDate == null)
                            ? null
                            : _resetDates,
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // مفاتيح الإظهار داخل بطاقات نيومورفيزم خفيفة (أفقية)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _toggleChip('السلف', _showLoans,
                            (v) => setState(() => _showLoans = v)),
                        const SizedBox(width: 10),
                        _toggleChip('الخصومات', _showDiscounts,
                            (v) => setState(() => _showDiscounts = v)),
                        const SizedBox(width: 10),
                        _toggleChip('الرواتب', _showSalaries,
                            (v) => setState(() => _showSalaries = v)),
                      ],
                    ),
                  ),

                  const SizedBox(height: 6),
                  const Divider(height: 1),

                  const SizedBox(height: 8),

                  if (_busy) ...[
                    const SizedBox(height: 120),
                    const Center(child: CircularProgressIndicator()),
                  ] else ...[
                    if (_showLoans)
                      _buildSection(
                        title: 'السلف',
                        items: _filteredLoans,
                        total: _sumLoans(_filteredLoans),
                        itemBuilder: _buildLoanTile,
                      ),
                    if (_showDiscounts)
                      _buildSection(
                        title: 'الخصومات',
                        items: _filteredDiscounts,
                        total: _sumDiscounts(_filteredDiscounts),
                        itemBuilder: _buildDiscountTile,
                      ),
                    if (_showSalaries)
                      _buildSection(
                        title: 'الرواتب',
                        items: _filteredSalaries,
                        total: _sumSalaries(_filteredSalaries),
                        itemBuilder: _buildSalaryTile,
                      ),
                    if ((!_showLoans || _filteredLoans.isEmpty) &&
                        (!_showDiscounts || _filteredDiscounts.isEmpty) &&
                        (!_showSalaries || _filteredSalaries.isEmpty))
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                          child: Text('لا توجد عناصر لعرضها',
                              style: TextStyle(color: Colors.grey)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }

  /*──────── عناصر الواجهة المساعدة ────────*/

  Widget _toggleChip(String label, bool value, ValueChanged<bool> onChanged) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .85),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: kPrimaryColor,
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Map<String, dynamic>> items,
    required double total,
    required Widget Function(Map<String, dynamic>) itemBuilder,
  }) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12.0),
        child: Text('لا توجد عناصر في $title',
            style: const TextStyle(color: Colors.grey)),
      );
    }

    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          // رأس القسم (نيومورفيزم) مع “حبة” إجمالي
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: NeuCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: kPrimaryColor.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: const Icon(Icons.receipt_long_rounded,
                        color: kPrimaryColor, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                      ),
                    ),
                  ),
                  _pillStat(
                      'الإجمالي: ${_moneyFmt.format(total)}  •  العدد: ${items.length}'),
                ],
              ),
            ),
          ),

          // العناصر (Spacing 16/18 كما في TBIAN)
          ...items.map((e) => Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: itemBuilder(e),
              )),
        ],
      ),
    );
  }

  Widget _pillStat(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _loanTileCore({
    required String name,
    required DateTime? dt,
    required double amount,
    required double leftover,
  }) {
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
          padding: const EdgeInsets.all(8),
          child: const Icon(Icons.request_quote_rounded, color: kPrimaryColor),
        ),
        title: Text('سلفة: ${_moneyFmt.format(amount)}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          'الموظف: $name\n'
          'التاريخ: ${dt != null ? _dateTimeFmt.format(dt) : '—'}\n'
          'المتبقي: ${_moneyFmt.format(leftover)}',
          style: TextStyle(color: scheme.onSurface.withValues(alpha: .8)),
        ),
      ),
    );
  }

  Widget _discountTileCore({
    required String name,
    required DateTime? dt,
    required double amount,
    required String notes,
  }) {
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
          padding: const EdgeInsets.all(8),
          child: const Icon(Icons.percent_rounded, color: kPrimaryColor),
        ),
        title: Text('خصم: ${_moneyFmt.format(amount)}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          'الموظف: $name\n'
          'التاريخ: ${dt != null ? _dateTimeFmt.format(dt) : '—'}\n'
          'ملاحظات: $notes',
          style: TextStyle(color: scheme.onSurface.withValues(alpha: .8)),
        ),
      ),
    );
  }

  Widget _salaryTileCore({
    required String name,
    required DateTime? dt,
    required int year,
    required int month,
    required double finalSalary,
    required double ratioSum,
    required double loans,
    required double netPay,
  }) {
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
          padding: const EdgeInsets.all(8),
          child: const Icon(Icons.payments_rounded, color: kPrimaryColor),
        ),
        title: Text('الموظف: $name',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          'الشهر/السنة: $month/$year\n'
          'تاريخ الصرف: ${dt != null ? _dateTimeFmt.format(dt) : '—'}\n'
          'الراتب: ${_moneyFmt.format(finalSalary)}, '
          'النسب: ${_moneyFmt.format(ratioSum)}, '
          'سلف: ${_moneyFmt.format(loans)}, '
          'صافي: ${_moneyFmt.format(netPay)}',
          style: TextStyle(color: scheme.onSurface.withValues(alpha: .8)),
        ),
      ),
    );
  }

  /*──────── البنَّاؤون الخاصون بالعناصر ────────*/

  Widget _buildLoanTile(Map<String, dynamic> ln) {
    final name = _nameOf((ln['employeeId'] ?? 0) as int);
    final dt = DateTime.tryParse('${ln['loanDateTime'] ?? ''}');
    final amount = _asDouble(ln['loanAmount']);
    final leftover = _asDouble(ln['leftover']);
    return _loanTileCore(
        name: name, dt: dt, amount: amount, leftover: leftover);
  }

  Widget _buildDiscountTile(Map<String, dynamic> ds) {
    final name = _nameOf((ds['employeeId'] ?? 0) as int);
    final dt = DateTime.tryParse('${ds['discountDateTime'] ?? ''}');
    final amount = _asDouble(ds['amount']);
    final notes = (ds['notes'] ?? '').toString();
    return _discountTileCore(name: name, dt: dt, amount: amount, notes: notes);
  }

  Widget _buildSalaryTile(Map<String, dynamic> sal) {
    final name = _nameOf((sal['employeeId'] ?? 0) as int);
    final dt = DateTime.tryParse('${sal['paymentDate'] ?? ''}');
    final y = (sal['year'] ?? 0) as int;
    final m = (sal['month'] ?? 0) as int;
    final finalSalary = _asDouble(sal['finalSalary']);
    final ratioSum = _asDouble(sal['ratioSum']);
    final loans = _asDouble(sal['totalLoans']);
    final netPay = _asDouble(sal['netPay']);
    return _salaryTileCore(
      name: name,
      dt: dt,
      year: y,
      month: m,
      finalSalary: finalSalary,
      ratioSum: ratioSum,
      loans: loans,
      netPay: netPay,
    );
  }
}
