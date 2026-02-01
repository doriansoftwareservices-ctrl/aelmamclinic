// lib/screens/repository/purchases_consumptions/pc_menu_screen.dart

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

/// القائمة الفرعية للمشتريات والاستهلاكات ببصمة TBIAN/Neumorphism
class PcMenuScreen extends StatelessWidget {
  const PcMenuScreen({super.key});

  static const routeName = '/repository/pc/menu';

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
              title: 'المشتريات والاستهلاكات',
              items: [
                FeatureHubItem(
                  icon: Icons.add_shopping_cart_outlined,
                  title: 'إنشاء مشتريات جديدة',
                  subtitle: 'إدخال فاتورة شراء وتحديث المخزون',
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/pc/new'),
                ),
                FeatureHubItem(
                  icon: Icons.receipt_long_outlined,
                  title: 'عرض المشتريات والاستهلاكات',
                  subtitle: 'استعراض/فلترة الفواتير وحركات الصرف',
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/pc/view'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
