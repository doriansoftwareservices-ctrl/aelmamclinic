// lib/screens/employees/finance/employees_finance_home_screen.dart
//
// شاشة المالية للموظفين بأسلوب TBIAN

import 'package:flutter/material.dart';

/*── TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'finance_access_guard.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

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
    return FinanceAccessGuard(
      child: Directionality(
        textDirection: Directionality.of(context),
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
              child: FeatureHubBody(
                title: 'المالية للموظفين',
                items: [
                  FeatureHubItem(
                    icon: Icons.request_quote_outlined,
                    title: 'إنشاء معاملة سُلَف',
                    subtitle: 'تسجيل سلفة جديدة ومتابعة المستحقات.',
                    onTap: () => _go(context, const EmployeeLoanHomeScreen()),
                  ),
                  FeatureHubItem(
                    icon: Icons.discount_outlined,
                    title: 'إنشاء معاملة خصم',
                    subtitle: 'إضافة خصم وربطه بالموظف المعني.',
                    onTap: () =>
                        _go(context, const EmployeeDiscountHomeScreen()),
                  ),
                  FeatureHubItem(
                    icon: Icons.payments_outlined,
                    title: 'إنشاء صرف الراتب',
                    subtitle: 'تسجيل صرف راتب مع تفاصيل المدفوعات.',
                    onTap: () =>
                        _go(context, const CreateSalaryPaymentScreen()),
                  ),
                  FeatureHubItem(
                    icon: Icons.insights_outlined,
                    title: 'الاستعراض (ملخّص)',
                    subtitle: 'عرض ملخص الرواتب والسلف والخصومات.',
                    onTap: () =>
                        _go(context, const EmployeesFinanceSummaryScreen()),
                  ),
                  FeatureHubItem(
                    icon: Icons.receipt_long_outlined,
                    title: 'المعاملات',
                    subtitle: 'استعراض الحركات المالية التفصيلية.',
                    onTap: () =>
                        _go(context, const EmployeesTransactionsScreen()),
                  ),
                  FeatureHubItem(
                    icon: Icons.history_rounded,
                    title: 'سجلات المعاملات',
                    subtitle: 'سجل التعديلات والإجراءات المالية.',
                    onTap: () => _go(context, const FinancialLogsScreen()),
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
