// lib/screens/services/doctors_services_home_screen.dart

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

import 'doctors_services_list_screen.dart';

class DoctorsServicesHomeScreen extends StatelessWidget {
  const DoctorsServicesHomeScreen({super.key});

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
              title: 'قوائم خدمات الأطباء',
              items: [
                FeatureHubItem(
                  icon: Icons.list_alt_rounded,
                  title: 'خدمات الأطباء',
                  subtitle: 'إدارة جميع الخدمات للطبيب العام/التخصصي',
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const DoctorsServicesListScreen()),
                    );
                  },
                ),
                FeatureHubItem(
                  icon: Icons.percent_rounded,
                  title: 'النِّسب الخاصة بالأطباء',
                  subtitle:
                      'تحديث نسب المشاركة ونسبة الأطباء من الأشعة والمختبرات',
                  badgeText: 'تحت التطوير',
                  disabled: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
