// lib/screens/repository/alerts/alert_menu_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

/// القائمة الفرعيّة لتنبيهات «قرب النفاد» بتصميم موحّد مع شاشات TBIAN.
class AlertMenuScreen extends StatelessWidget {
  const AlertMenuScreen({super.key});

  static const routeName = '/repository/alerts';

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
              title: 'تنبيه قرب النفاد',
              items: [
                FeatureHubItem(
                  icon: Icons.add_alert_outlined,
                  title: 'إنشاء توقيت تنبيه',
                  subtitle: 'ضبط شرط ومستوى الكمية',
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/alerts/create'),
                ),
                FeatureHubItem(
                  icon: Icons.notifications_active_outlined,
                  title: 'استعراض التنبيهات',
                  subtitle: 'عرض التنبيهات الحالية وإدارتها',
                  onTap: () =>
                      Navigator.pushNamed(context, '/repository/alerts/view'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
