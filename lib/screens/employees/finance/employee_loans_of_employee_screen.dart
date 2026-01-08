// lib/screens/employees/finance/employee_loans_of_employee_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui show TextDirection;
/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/logging_service.dart';
import 'employee_loan_create_screen.dart';
import 'finance_access_guard.dart';

class EmployeeLoansOfEmployeeScreen extends StatefulWidget {
  final int empId;
  const EmployeeLoansOfEmployeeScreen({super.key, required this.empId});

  @override
  State<EmployeeLoansOfEmployeeScreen> createState() =>
      _EmployeeLoansOfEmployeeScreenState();
}

class _EmployeeLoansOfEmployeeScreenState
    extends State<EmployeeLoansOfEmployeeScreen> {
  List<Map<String, dynamic>> _allLoans = [];
  List<Map<String, dynamic>> _filteredLoans = [];

  DateTime? _startDate;
  DateTime? _endDate;

  final DateFormat _dateFmt = DateFormat('yyyy-MM-dd');
  final DateFormat _dateTimeFmt = DateFormat('yyyy-MM-dd HH:mm');

  String _employeeName = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadLoans();
  }

  Future<void> _loadLoans() async {
    setState(() => _loading = true);
    try {
      // اسم الموظف (لعنوان الشاشة)
      final emp = await DBService.instance.getEmployeeById(widget.empId);
      _employeeName = (emp?['name'] ?? '').toString();

      // جلب السلف ثم فلترة حسب الموظف + فرز تنازلي بالتاريخ
      final all = await DBService.instance.getAllEmployeeLoans();
      final empLoans = all
          .where((l) => l['employeeId'] == widget.empId)
          .toList()
        ..sort((a, b) {
          final ad = DateTime.tryParse(a['loanDateTime']?.toString() ?? '') ??
              DateTime(1970);
          final bd = DateTime.tryParse(b['loanDateTime']?.toString() ?? '') ??
              DateTime(1970);
          return bd.compareTo(ad);
        });

      setState(() {
        _allLoans = empLoans;
        _filteredLoans = List.from(empLoans);
      });
      _applyFilter(); // إعادة تطبيق الفلاتر إن كانت موجودة
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّرت قراءة السلف: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart
          ? (_startDate ?? DateTime.now())
          : (_endDate ?? DateTime.now()),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(
            primary: scheme.primary,
          ),
        ),
        child: child!,
      ),
      locale: const Locale('ar', ''),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = DateTime(picked.year, picked.month, picked.day);
        } else {
          _endDate =
              DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
        }
      });
      _applyFilter();
    }
  }

  void _resetDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _filteredLoans = List.from(_allLoans);
    });
  }

  void _applyFilter() {
    if (_startDate == null && _endDate == null) {
      setState(() => _filteredLoans = List.from(_allLoans));
      return;
    }
    final filtered = _allLoans.where((loan) {
      final dt = DateTime.tryParse(loan['loanDateTime']?.toString() ?? '');
      if (dt == null) return false;
      if (_startDate != null && dt.isBefore(_startDate!)) return false;
      if (_endDate != null && dt.isAfter(_endDate!)) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final ad = DateTime.tryParse(a['loanDateTime']?.toString() ?? '') ??
            DateTime(1970);
        final bd = DateTime.tryParse(b['loanDateTime']?.toString() ?? '') ??
            DateTime(1970);
        return bd.compareTo(ad);
      });

    setState(() => _filteredLoans = filtered);
  }

  Future<void> _deleteLoan(int loanId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text('هل تريد حذف السلفة؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await DBService.instance.deleteEmployeeLoan(loanId);

      // تسجيل العملية
      LoggingService().logTransaction(
        transactionType: "Loan",
        operation: "delete",
        amount: 0.0,
        employeeId: widget.empId,
        description: "تم حذف سلفة (ID: $loanId) للموظف ${widget.empId}",
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف السلفة بنجاح')),
      );
      _loadLoans();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل حذف السلفة: $e')),
      );
    }
  }

  double get _totalLoanAmount => _filteredLoans.fold<double>(
        0.0,
        (sum, l) => sum + ((l['loanAmount'] as num?)?.toDouble() ?? 0.0),
      );

  double get _totalLeftover => _filteredLoans.fold<double>(
        0.0,
        (sum, l) => sum + ((l['leftover'] as num?)?.toDouble() ?? 0.0),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = _employeeName.isEmpty ? 'سلف الموظف' : 'سلف $_employeeName';

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
              Text(title),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: const Text('سلفة جديدة'),
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => EmployeeLoanCreateScreen(empId: widget.empId),
              ),
            );
            _loadLoans();
          },
        ),
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    /*──────── بطاقة رأس ────────*/
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                      child: NeuCard(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: kPrimaryColor.withValues(alpha: .10),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.all(10),
                              child: const Icon(
                                Icons.request_quote_rounded,
                                color: kPrimaryColor,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'السلف الخاصة بالموظف',
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    /*──────── مرشّحات التاريخ بنمط TBIAN ────────*/
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
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
                    ),

                    /*──────── إحصاءات مختصرة ────────*/
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                      child: NeuCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _StatChip(
                                label: 'عدد السلف',
                                value: '${_filteredLoans.length}',
                              ),
                              const SizedBox(width: 10),
                              _StatChip(
                                label: 'إجمالي السلف',
                                value: _totalLoanAmount.toStringAsFixed(2),
                              ),
                              const SizedBox(width: 10),
                              _StatChip(
                                label: 'إجمالي المتبقي',
                                value: _totalLeftover.toStringAsFixed(2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    /*──────── القائمة ────────*/
                    Expanded(
                      child: _filteredLoans.isEmpty
                          ? Center(
                              child: Text(
                                'لا توجد سلف لهذا الموظف',
                                style: TextStyle(
                                  color: scheme.onSurface.withValues(alpha: .6),
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : RefreshIndicator(
                              color: scheme.primary,
                              onRefresh: _loadLoans,
                              child: ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.fromLTRB(16, 8, 16, 16),
                                itemCount: _filteredLoans.length,
                                itemBuilder: (ctx, i) {
                                  final loan = _filteredLoans[i];
                                  final dt = DateTime.tryParse(
                                              loan['loanDateTime']
                                                      ?.toString() ??
                                                  '')
                                          ?.toLocal() ??
                                      DateTime(1970, 1, 1);
                                  final amt = ((loan['loanAmount'] as num?)
                                          ?.toDouble() ??
                                      0.0);
                                  final left =
                                      ((loan['leftover'] as num?)?.toDouble() ??
                                          0.0);
                                  final id = (loan['id'] as num?)?.toInt();

                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: NeuCard(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 6),
                                      child: ListTile(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 8),
                                        title: Text(
                                          'سلفة: ${amt.toStringAsFixed(2)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        subtitle: Text(
                                          'التاريخ: ${_dateTimeFmt.format(dt)} • المتبقي: ${left.toStringAsFixed(2)}',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: scheme.onSurface
                                                .withValues(alpha: .75),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        trailing: IconButton(
                                          tooltip: 'حذف',
                                          icon: const Icon(Icons.delete_outline,
                                              color: Colors.red),
                                          onPressed: id == null
                                              ? null
                                              : () => _deleteLoan(id),
                                        ),
                                      ),
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
    );
  }
}

/*──────── شريحة إحصائية صغيرة داخل NeuCard ────────*/
class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .75),
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
