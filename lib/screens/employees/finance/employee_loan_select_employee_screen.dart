// lib/screens/employees/finance/employee_loan_select_employee_screen.dart

import 'package:flutter/material.dart';
// لاستخراج أول محرف (grapheme)
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'employee_loan_create_screen.dart';
import 'employee_loans_of_employee_screen.dart';
import 'finance_access_guard.dart';

class EmployeeLoanSelectEmployeeScreen extends StatefulWidget {
  final bool isCreateMode;
  const EmployeeLoanSelectEmployeeScreen({
    super.key,
    required this.isCreateMode,
  });

  @override
  State<EmployeeLoanSelectEmployeeScreen> createState() =>
      _EmployeeLoanSelectEmployeeScreenState();
}

class _EmployeeLoanSelectEmployeeScreenState
    extends State<EmployeeLoanSelectEmployeeScreen> {
  List<Map<String, dynamic>> _allEmployees = [];
  List<Map<String, dynamic>> _filteredEmployees = [];
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = false;

  String get _screenTitle => widget.isCreateMode
      ? 'اختر الموظف (سلفة جديدة)'
      : 'اختر الموظف (استعراض السلف)';

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _searchController.addListener(_filterEmployees);
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterEmployees);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEmployees() async {
    setState(() => _isLoading = true);
    try {
      final data = await DBService.instance.getAllEmployees();
      if (!mounted) return;
      setState(() {
        _allEmployees = data;
        _filteredEmployees = data;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر جلب الموظفين: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterEmployees() {
    final q = _searchController.text.trim().toLowerCase();
    setState(() {
      _filteredEmployees = _allEmployees.where((emp) {
        final name = (emp['name'] ?? '').toString().toLowerCase();
        final identity = (emp['identityNumber'] ?? '').toString().toLowerCase();
        final phone = (emp['phoneNumber'] ?? '').toString().toLowerCase();
        final jobTitle = (emp['jobTitle'] ?? '').toString().toLowerCase();
        return q.isEmpty ||
            name.contains(q) ||
            identity.contains(q) ||
            phone.contains(q) ||
            jobTitle.contains(q);
      }).toList();
    });
  }

  void _onEmployeeSelected(int empId) {
    final next = widget.isCreateMode
        ? EmployeeLoanCreateScreen(empId: empId)
        : EmployeeLoansOfEmployeeScreen(empId: empId);
    Navigator.push(context, MaterialPageRoute(builder: (_) => next));
  }

  String _initialLetter(dynamic name) {
    final s = (name ?? '').toString().trim();
    if (s.isEmpty) return '—';
    return s.characters.first;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return FinanceAccessGuard(
      child: Directionality(
        textDirection: TextDirection.rtl,
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
          child: Column(
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
                          _screenTitle,
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

              /*──────── شريط البحث ────────*/
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TSearchField(
                  controller: _searchController,
                  hint: 'ابحث بالاسم/الوظيفة/الهاتف/الهوية…',
                  onChanged: (_) => _filterEmployees(),
                  onClear: () {
                    _searchController.clear();
                    _filterEmployees();
                    FocusScope.of(context).unfocus();
                  },
                ),
              ),

              /*──────── القائمة ────────*/
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _filteredEmployees.isEmpty
                        ? Center(
                            child: Text(
                              'لا توجد نتائج',
                              style: TextStyle(
                                color: scheme.onSurface.withValues(alpha: .6),
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            color: scheme.primary,
                            onRefresh: _loadEmployees,
                            child: ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                              itemCount: _filteredEmployees.length,
                              itemBuilder: (ctx, i) {
                                final emp = _filteredEmployees[i];
                                final empIdNum = (emp['id'] ?? 0);
                                final empId = (empIdNum is num)
                                    ? empIdNum.toInt()
                                    : int.tryParse(empIdNum.toString()) ?? 0;
                                final name = (emp['name'] ?? '').toString();
                                final jobTitle =
                                    (emp['jobTitle'] ?? '').toString();

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: NeuCard(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 6),
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 6),
                                      leading: CircleAvatar(
                                        radius: 22,
                                        backgroundColor: kPrimaryColor,
                                        child: Text(
                                          _initialLetter(name),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      title: Text(
                                        name.isEmpty ? '—' : name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800),
                                      ),
                                      subtitle: Text(
                                        jobTitle.isEmpty ? '—' : jobTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: scheme.onSurface
                                              .withValues(alpha: .75),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      trailing: const Icon(
                                          Icons.chevron_left_rounded),
                                      onTap: () => _onEmployeeSelected(empId),
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
