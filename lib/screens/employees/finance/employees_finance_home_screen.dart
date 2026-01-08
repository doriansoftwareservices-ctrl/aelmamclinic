// lib/screens/employees/finance/employees_finance_home_screen.dart
//
// شاشة المالية للموظفين بأسلوب TBIAN

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'finance_access_guard.dart';

/*── شاشات الوجهات ─*/
import 'employee_loan_home_screen.dart';
import 'create_salary_payment_screen.dart';
import 'employees_finance_summary_screen.dart';
import 'employees_transactions_screen.dart';
import 'employee_discount_home_screen.dart';
import 'financial_logs_screen.dart';

class EmployeesFinanceHomeScreen extends StatelessWidget {
  const EmployeesFinanceHomeScreen({super.key});

  void _go(BuildContext context, Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
          child: SingleChildScrollView(
            padding: kScreenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'المالية للموظفين',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),

                // شبكة بطاقات الإجراءات
                Directionality(
                  textDirection: ui.TextDirection.rtl,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 16,
                    runSpacing: 18,
                    children: [
                      _ActionCard(
                        icon: Icons.request_quote_outlined,
                        label: 'إنشاء معاملة سُلَف',
                        onTap: () =>
                            _go(context, const EmployeeLoanHomeScreen()),
                      ),
                      _ActionCard(
                        icon: Icons.discount_outlined,
                        label: 'إنشاء معاملة خصم',
                        onTap: () =>
                            _go(context, const EmployeeDiscountHomeScreen()),
                      ),
                      _ActionCard(
                        icon: Icons.payments_outlined,
                        label: 'إنشاء صرف الراتب',
                        onTap: () =>
                            _go(context, const CreateSalaryPaymentScreen()),
                      ),
                      _ActionCard(
                        icon: Icons.insights_outlined,
                        label: 'الاستعراض (ملخّص)',
                        onTap: () =>
                            _go(context, const EmployeesFinanceSummaryScreen()),
                      ),
                      _ActionCard(
                        icon: Icons.receipt_long_outlined,
                        label: 'المعاملات',
                        onTap: () =>
                            _go(context, const EmployeesTransactionsScreen()),
                      ),
                      _ActionCard(
                        icon: Icons.history_rounded,
                        label: 'سجلات المعاملات',
                        onTap: () => _go(context, const FinancialLogsScreen()),
                      ),
                    ],
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

/*──────── بطاقة إجراء بنمط TBIAN/Neumorphism ────────*/
class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: label,
      child: NeuCard(
        onTap: onTap,
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 220,
          height: 110,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // أيقونة داخل حاوية أولية شبه شفافة
              Container(
                decoration: BoxDecoration(
                  color: kPrimaryColor.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.all(10),
                child: Icon(icon, color: kPrimaryColor, size: 24),
              ),
              const SizedBox(height: 12),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
