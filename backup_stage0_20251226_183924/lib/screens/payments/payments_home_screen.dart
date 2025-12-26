// lib/screens/payments/payments_home_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

import 'package:aelmamclinic/screens/consumption/list_consumption_screen.dart';
import 'package:aelmamclinic/screens/consumption/new_consumption_screen.dart';
import 'package:aelmamclinic/screens/employees/finance/employees_finance_home_screen.dart';

/* تصميم TBIAN */
import 'package:aelmamclinic/core/neumorphism.dart';

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
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          elevation: 4,
          centerTitle: true,
          title: const Text('الشؤون المالية',
              style: TextStyle(fontWeight: FontWeight.bold)),
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [scheme.primaryContainer, scheme.primary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.surfaceContainerHigh,
                scheme.surface,
                scheme.surfaceContainerHigh
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Center(
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              runSpacing: 18,
              children: [
                _ActionCard(
                  icon: Icons.inventory_2_rounded,
                  title: 'استهلاكات المرفق الطبي',
                  subtitle: 'إضافة أو استعراض',
                  onTap: () => _showConsumptionMenu(context),
                ),
                _ActionCard(
                  icon: Icons.payments_rounded,
                  title: 'المالية',
                  subtitle: 'ملخصات وحسابات',
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

/* بطاقة إجراء بنمط TBIAN/Neumorphism */
class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: SizedBox(
        width: 260,
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(12),
              child: Icon(icon, color: scheme.primary, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .90),
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                      )),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .65),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_left_rounded,
                color: scheme.onSurface.withValues(alpha: .6)),
          ],
        ),
      ),
    );
  }
}
