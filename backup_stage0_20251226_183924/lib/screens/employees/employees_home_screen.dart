// lib/screens/employees/employees_home_screen.dart
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

// شاشات نحتاجها
import 'package:aelmamclinic/screens/doctors/doctors_home_screen.dart';
import 'new_employee_screen.dart';
import 'list_employees_screen.dart';

/// الشاشة الرئيسية لإدارة الموظفين بنمط TBIAN (RTL + نيومورفيزم + AppBar موحّد)
class EmployeesHomeScreen extends StatelessWidget {
  const EmployeesHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final crossAxis = width >= 1200
        ? 4
        : width >= 900
            ? 3
            : width >= 600
                ? 2
                : 1;
    final aspect = width >= 1200
        ? 1.25
        : width >= 900
            ? 1.15
            : 1.05;

    return Directionality(
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
                /*──────── بطاقة الرأس ────────*/
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
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.apartment_rounded),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'إدارة الموظفين',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
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
                      _ActionTile(
                        icon: Icons.local_hospital_rounded,
                        title: 'الأطباء',
                        subtitle: 'إدارة شاشات وسجلات الأطباء.',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DoctorsHomeScreen(),
                            ),
                          );
                        },
                      ),
                      _ActionTile(
                        icon: Icons.person_add_alt_1_rounded,
                        title: 'إنشاء موظف',
                        subtitle: 'إضافة موظف جديد وربطه لاحقًا كطبيب إن لزم.',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const NewEmployeeScreen(),
                            ),
                          );
                        },
                      ),
                      _ActionTile(
                        icon: Icons.list_alt_rounded,
                        title: 'قائمة الموظفين',
                        subtitle: 'عرض، بحث، مشاركة وتعديل بيانات الموظفين.',
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ListEmployeesScreen(),
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
    );
  }
}

/*──────── بطاقة إجراء داخل الشبكة ────────*/
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
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
          // أيقونة مزخرفة داخل حاوية بلون أساسي شفاف
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
            // نستخدم TPrimaryButton (تغليف لِـ NeuButton.flat) للمطابقة مع حزمة TBIAN
            child: TPrimaryButton(
              icon: Icons.arrow_back_ios_new_rounded, // RTL: سهم يسار بصريًا
              label: 'فتح',
              onPressed: onTap,
            ),
          ),
        ],
      ),
    );
  }
}
