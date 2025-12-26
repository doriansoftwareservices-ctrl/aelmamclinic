// lib/screens/employees/finance/employee_discount_home_screen.dart
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'employee_discount_select_employee_screen.dart';

class EmployeeDiscountHomeScreen extends StatelessWidget {
  const EmployeeDiscountHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final crossAxis = width >= 1200 ? 2 : 1;
    final aspect = width >= 1200 ? 1.35 : 1.08;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.receipt_long_rounded),
              SizedBox(width: 8),
              Text('معاملة الخصومات'),
            ],
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // بطاقة رأس منسّقة أسلوب TBIAN (شعار + عنوان)
                NeuCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: Image.asset(
                            'assets/images/logo.png',
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.percent_rounded,
                                color: kPrimaryColor,
                                size: 28),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'إدارة الخصومات الخاصة بالموظفين',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // نص توضيحي صغير
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'اختر العملية المطلوبة للمتابعة:',
                    style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: .65),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // شبكة الإجراءات (متجاوبة)
                Expanded(
                  child: GridView.count(
                    crossAxisCount: crossAxis,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: aspect,
                    children: [
                      _ActionCard(
                        icon: Icons.add_circle_outline_rounded,
                        title: 'إنشاء خصم جديد',
                        subtitle:
                            'إنشاء إدخال خصم على موظف محدّد مع اختيار التاريخ والوقت وتوثيق السبب.',
                        buttonLabel: 'ابدأ الآن',
                        onPressed: () {
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
                      _ActionCard(
                        icon: Icons.history_rounded,
                        title: 'استعراض الخصومات',
                        subtitle:
                            'استعراض الخصومات السابقة حسب الموظف للاطلاع والتتبّع.',
                        buttonLabel: 'فتح السجل',
                        onPressed: () {
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

                // تلميحات قصيرة
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: const Icon(Icons.info_outline,
                            color: kPrimaryColor, size: 18),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'تذكير: عند إنشاء خصم للطبيب، سيتم احتساب النِّسَب ومدخلات الشهر حسب تاريخ الخصم.',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: .75),
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
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

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final VoidCallback onPressed;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: title,
      hint: subtitle,
      child: NeuCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // أيقونة أمامية منسّقة
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                decoration: BoxDecoration(
                  color: kPrimaryColor.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.all(10),
                child: Icon(icon, color: kPrimaryColor, size: 26),
              ),
            ),
            const SizedBox(height: 12),

            // العنوان
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),

            // الوصف
            Expanded(
              child: Text(
                subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .65),
                  fontSize: 13.2,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
            ),
            const SizedBox(height: 10),

            // زر الإجراء
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: NeuButton.primary(
                label: buttonLabel,
                icon:
                    Icons.arrow_back_ios_new_rounded, // RTL → سهم لليسار بصريًا
                onPressed: onPressed,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
