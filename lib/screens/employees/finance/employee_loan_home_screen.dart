// lib/screens/employees/finance/employee_loan_home_screen.dart
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

import 'employee_loan_select_employee_screen.dart';
import 'finance_access_guard.dart';

/// شاشة «معاملة السلفة» بنمط TBIAN:
/// - RTL افتراضيًا
/// - AppBar موحّد مع الشعار
/// - بطاقات نيومورفيزم كبيرة بخيارات رئيسية
class EmployeeLoanHomeScreen extends StatelessWidget {
  const EmployeeLoanHomeScreen({super.key});

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
              title: 'معاملة السلفة',
              items: [
                FeatureHubItem(
                  icon: Icons.request_quote_rounded,
                  title: 'إنشاء سلفة جديدة',
                  subtitle:
                      'اختَر الموظف ثم أدخل قيمة السلفة وتاريخها وطريقة الصرف.',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const EmployeeLoanSelectEmployeeScreen(
                          isCreateMode: true,
                        ),
                      ),
                    );
                  },
                ),
                FeatureHubItem(
                  icon: Icons.receipt_long_rounded,
                  title: 'استعراض السلف للموظفين',
                  subtitle:
                      'ابحث واستعرض سلف جميع الموظفين مع إمكانيات التعديل والإلغاء.',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const EmployeeLoanSelectEmployeeScreen(
                          isCreateMode: false,
                        ),
                      ),
                    );
                  },
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
