// lib/screens/lab_and_radiology_home_screen.dart

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

/*── شاشات نفس المجلد ─*/
import 'radiology_services_screen.dart';
import 'lab_services_screen.dart';

/*── شاشة تقرير الطبيب للأشعة والمختبر (كما في كودك) ─*/
import 'package:aelmamclinic/screens/doctors/doctor_imaging_lab_report_screen.dart';

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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              // رأس الصفحة وفق بصمة TBIAN
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: const Icon(Icons.medical_services_rounded,
                          color: kPrimaryColor, size: 22),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'المختبر والأشعة',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // شبكة الأزرار الرئيسية (Neumorphism)
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 16,
                children: [
                  _MenuTile(
                    icon: Icons.biotech_rounded,
                    title: 'الأشعة',
                    subtitle: 'إدارة خدمات قسم الأشعة',
                    onTap: () => _openRadiology(context),
                  ),
                  _MenuTile(
                    icon: Icons.science_rounded,
                    title: 'المختبر',
                    subtitle: 'إدارة خدمات قسم المختبر',
                    onTap: () => _openLab(context),
                  ),
                  _MenuTile(
                    icon: Icons.assignment_rounded,
                    title: 'تقرير الطبيب',
                    subtitle: 'تقرير الطبيب للأشعة والمختبر',
                    onTap: () => _openDoctorReport(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// بطاقة قائمة رئيسية وفق TBIAN/Neumorphism
class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 320,
      child: NeuCard(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            // أيقونة داخل كبسولة ملوّنة خفيفة
            Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(12),
              child: Icon(icon, color: kPrimaryColor, size: 22),
            ),
            const SizedBox(width: 12),
            // نصوص
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w900, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: .75),
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.chevron_left_rounded,
                color: scheme.onSurface.withValues(alpha: .6)),
          ],
        ),
      ),
    );
  }
}
