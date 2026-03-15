// lib/screens/lab_and_radiology_home_screen.dart

import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/widgets/feature_hub.dart';

/*── شاشات نفس المجلد ─*/
import 'radiology_services_screen.dart';
import 'lab_services_screen.dart';

/*── شاشة تقرير الطبيب للأشعة والمختبر (كما في كودك) ─*/
import 'package:aelmamclinic/screens/doctors/doctor_imaging_lab_report_screen.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class LabAndRadiologyHomeScreen extends StatelessWidget {
  const LabAndRadiologyHomeScreen({super.key});

  void _openRadiology(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RadiologyServicesScreen()),
    );
  }

  void _openLab(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LabServicesScreen()),
    );
  }

  void _openDoctorReport(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DoctorImagingLabReportScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
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
              title: 'المختبر والأشعة',
              items: [
                FeatureHubItem(
                  icon: Icons.biotech_rounded,
                  title: 'الأشعة',
                  subtitle: 'إدارة خدمات قسم الأشعة',
                  badgeText: context.trRaw('تحت التطوير'),
                  disabled: true,
                  onTap: () => _openRadiology(context),
                ),
                FeatureHubItem(
                  icon: Icons.science_rounded,
                  title: 'المختبر',
                  subtitle: 'إدارة خدمات قسم المختبر',
                  badgeText: context.trRaw('تحت التطوير'),
                  disabled: true,
                  onTap: () => _openLab(context),
                ),
                FeatureHubItem(
                  icon: Icons.assignment_rounded,
                  title: 'تقرير الطبيب',
                  subtitle: 'تقرير الطبيب للأشعة والمختبر',
                  badgeText: context.trRaw('تحت التطوير'),
                  disabled: true,
                  onTap: () => _openDoctorReport(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
