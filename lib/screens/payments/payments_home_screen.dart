// lib/screens/payments/payments_home_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

import 'package:aelmamclinic/screens/consumption/list_consumption_screen.dart';
import 'package:aelmamclinic/screens/consumption/new_consumption_screen.dart';
import 'package:aelmamclinic/screens/employees/finance/employees_finance_home_screen.dart';

/* تصميم TBIAN */
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

class PaymentsHomeScreen extends StatelessWidget {
  const PaymentsHomeScreen({super.key});

  void _showConsumptionMenu(BuildContext ctx) {
    final scheme = Theme.of(ctx).colorScheme;
    showModalBottomSheet(
      context: ctx,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant.withValues(alpha: .6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: ListTile(
                  leading: const Icon(Icons.add_circle_outline),
                  title: const Text('إضافة مبلغ المصروفات / الاستهلاكات',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      ctx,
                      MaterialPageRoute(builder: (_) => NewConsumptionScreen()),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: ListTile(
                  leading: const Icon(Icons.list_alt_outlined),
                  title: const Text('استعراض المصروفات / الاستهلاكات',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  trailing: const Icon(Icons.chevron_left_rounded),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      ctx,
                      MaterialPageRoute(
                          builder: (_) => ListConsumptionScreen()),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            child: FeatureHubBody(
              title: 'الشؤون المالية',
              items: [
                FeatureHubItem(
                  icon: Icons.inventory_2_rounded,
                  title: 'استهلاكات المرفق الطبي',
                  subtitle: 'إضافة أو استعراض المصروفات والاستهلاكات.',
                  onTap: () => _showConsumptionMenu(context),
                ),
                FeatureHubItem(
                  icon: Icons.payments_rounded,
                  title: 'المالية',
                  subtitle: 'ملخصات وحسابات الموظفين.',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const EmployeesFinanceHomeScreen()),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
