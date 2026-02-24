// lib/screens/repository/menu/repository_menu_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/screens/repository/health/repository_health_screen.dart';

class RepositoryMenuScreen extends StatelessWidget {
  const RepositoryMenuScreen({super.key});

  static const routeName = '/repository/menu';

  @override
  Widget build(BuildContext context) {
    final repoProvider = context.watch<RepositoryProvider>();

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
          leading: IconButton(
            tooltip: 'رجوع',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: FeatureHubBody(
              title: 'قسم المستودع',
              items: [
                FeatureHubItem(
                  icon: Icons.add_box_outlined,
                  title: 'إضافة صنف جديد',
                  subtitle: 'إضافة صنف جديد للمستودع.',
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/items/add'),
                ),
                FeatureHubItem(
                  icon: Icons.view_list_outlined,
                  title: 'استعراض الأصناف المضافة',
                  subtitle: 'قائمة الأصناف مع تفاصيل المخزون.',
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/items/view'),
                ),
                FeatureHubItem(
                  icon: Icons.swap_vert_circle_outlined,
                  title: 'مشتريات واستهلاكات المستودع',
                  subtitle: 'إدارة المشتريات والاستهلاكات اليومية.',
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/pc/menu'),
                ),
                FeatureHubItem(
                  icon: Icons.insights_outlined,
                  title: 'إحصائيات وكشوفات المستودع',
                  subtitle: 'تقارير وإحصاءات المخزون.',
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/statistics'),
                ),
                FeatureHubItem(
                  icon: Icons.notifications_active_outlined,
                  title: 'تنبيه قرب النفاد',
                  subtitle: 'تنبيهات الأصناف منخفضة الكمية.',
                  badgeText: repoProvider.hasLowStockBadge ? 'تنبيه' : null,
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/alerts'),
                ),
                FeatureHubItem(
                  icon: Icons.health_and_safety_outlined,
                  title: 'تشخيص صحة المستودع',
                  subtitle: 'فحص سريع للعلاقات والبيانات المفقودة.',
                  onTap: () => Navigator.pushNamed(
                    context,
                    RepositoryHealthScreen.routeName,
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
