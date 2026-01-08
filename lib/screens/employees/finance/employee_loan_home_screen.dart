// lib/screens/employees/finance/employee_loan_home_screen.dart
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

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
    final width = MediaQuery.sizeOf(context).width;
    final crossAxis = width >= 1200
        ? 3
        : width >= 900
            ? 2
            : 1;
    final aspect = width >= 1200
        ? 1.2
        : width >= 900
            ? 1.1
            : 1.05;

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
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                /*──────── بطاقة رأس ────────*/
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
                                Icons.account_balance_wallet_outlined),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: const [
                            Text(
                              'معاملة السلفة',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'إدارة سلف الموظفين: إنشاء واستعراض.',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.black54,
                              ),
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                /*──────── الشبكة ────────*/
                Expanded(
                  child: GridView.count(
                    crossAxisCount: crossAxis,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: aspect,
                    children: [
                      _LoanActionTile(
                        icon: Icons.request_quote_rounded,
                        title: 'إنشاء سلفة جديدة',
                        subtitle:
                            'اختَر الموظف ثم أدخل قيمة السلفة وتاريخها وطريقة الصرف.',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const EmployeeLoanSelectEmployeeScreen(
                                isCreateMode: true,
                              ),
                            ),
                          );
                        },
                      ),
                      _LoanActionTile(
                        icon: Icons.receipt_long_rounded,
                        title: 'استعراض السلف للموظفين',
                        subtitle:
                            'ابحث واستعرض سلف جميع الموظفين مع إمكانيات التعديل والإلغاء.',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const EmployeeLoanSelectEmployeeScreen(
                                isCreateMode: false,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
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

/*──────── بطاقة إجراء (نيومورفيزم) ────────*/
class _LoanActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _LoanActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // أيقونة داخل حاوية أساسية شبه شفافة (تماشيًا مع شاشات TBIAN)
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
          Align(
            alignment: AlignmentDirectional.centerEnd,
            // نستخدم TPrimaryButton (تغليف لِـ NeuButton.flat) للمطابقة مع أسلوب الحزمة
            child: TPrimaryButton(
              icon: Icons.arrow_back_ios_new_rounded, // RTL: سهم بصريًا لليسار
              label: 'فتح',
              onPressed: onTap,
            ),
          ),
        ],
      ),
    );
  }
}
