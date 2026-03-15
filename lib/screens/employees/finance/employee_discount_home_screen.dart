// lib/screens/employees/finance/employee_discount_home_screen.dart
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

import 'employee_discount_select_employee_screen.dart';
import 'finance_access_guard.dart';

class EmployeeDiscountHomeScreen extends StatelessWidget {
  const EmployeeDiscountHomeScreen({super.key});

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
              title: 'معاملة الخصومات',
              items: [
                FeatureHubItem(
                  icon: Icons.add_circle_outline_rounded,
                  title: 'إنشاء خصم جديد',
                  subtitle:
                      'إنشاء إدخال خصم على موظف محدّد مع اختيار التاريخ والوقت وتوثيق السبب.',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const EmployeeDiscountSelectEmployeeScreen(
                          isCreateMode: true,
                        ),
                      ),
                    );
                  },
                ),
                FeatureHubItem(
                  icon: Icons.history_rounded,
                  title: 'استعراض الخصومات',
                  subtitle:
                      'استعراض الخصومات السابقة حسب الموظف للاطلاع والتتبّع.',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const EmployeeDiscountSelectEmployeeScreen(
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
