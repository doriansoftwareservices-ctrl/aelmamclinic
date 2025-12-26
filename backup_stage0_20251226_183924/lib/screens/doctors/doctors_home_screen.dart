// lib/screens/doctors/doctors_home_screen.dart

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:aelmamclinic/providers/appointment_provider.dart';

// شاشات الأطباء
import 'new_doctor_screen.dart';
import 'list_doctors_screen.dart';
import 'doctors_patients_screen.dart';

// Placeholders المتبقي
import 'package:aelmamclinic/services/doctors_services_home_screen.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class DoctorsHomeScreen extends StatefulWidget {
  const DoctorsHomeScreen({super.key});

  @override
  State<DoctorsHomeScreen> createState() => _DoctorsHomeScreenState();
}

class _DoctorsHomeScreenState extends State<DoctorsHomeScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // تحميل المواعيد عند فتح الشاشة
    Future.microtask(() =>
        Provider.of<AppointmentProvider>(context, listen: false)
            .loadAppointments());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Provider.of<AppointmentProvider>(context, listen: false)
          .loadAppointments();
    }
  }

  void _go(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Consumer<AppointmentProvider>(
        builder: (context, appointmentProvider, _) {
          final hasReminder = appointmentProvider.hasTodayAppointments;

          return Scaffold(
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
                  const Text('الأطباء'),
                ],
              ),
              actions: [
                if (hasReminder)
                  IconButton(
                    tooltip: 'مواعيد اليوم',
                    onPressed: () {
                      // منطق الإشعارات إن لزم لاحقاً
                    },
                    icon: const Icon(Icons.notifications_active_rounded),
                  ),
              ],
            ),
            body: SafeArea(
              child: Padding(
                padding: kScreenPadding,
                child: LayoutBuilder(
                  builder: (context, cons) {
                    final width = cons.maxWidth;
                    final cross = width >= 1200
                        ? 4
                        : width >= 900
                            ? 3
                            : 2;
                    final aspect = width >= 1200
                        ? 1.12
                        : width >= 900
                            ? 1.02
                            : (width < 420 ? 0.90 : 0.86);

                    return GridView.count(
                      crossAxisCount: cross,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: aspect,
                      children: [
                        _HomeCard(
                          icon: Icons.person_add_alt_1_rounded,
                          title: 'إضافة طبيب',
                          subtitle:
                              'تسجيل طبيب جديد مع البيانات الأساسية ونسب الخدمات لاحقاً',
                          primary: ('فتح', () => _go(const NewDoctorScreen())),
                        ),
                        _HomeCard(
                          icon: Icons.list_alt_rounded,
                          title: 'قائمة الأطباء',
                          subtitle:
                              'استعراض وتعديل بيانات الأطباء الحاليين في العيادة',
                          primary: (
                            'استعراض',
                            () => _go(const ListDoctorsScreen())
                          ),
                        ),
                        _HomeCard(
                          icon: Icons.people_alt_rounded,
                          title: 'مرضى الأطباء',
                          subtitle:
                              'عرض المرضى المرتبطين بالأطباء مع تفاصيل الخدمة',
                          primary: (
                            'فتح',
                            () => _go(const DoctorsPatientsScreen()),
                          ),
                        ),
                        // ✅ تمت إزالة بطاقة المختبر والأشعة
                        _HomeCard(
                          icon: Icons.medical_services_rounded,
                          title: 'قوائم خدمات الأطباء',
                          subtitle:
                              'تحديد نسب الطبيب ونسبة المركز لخدمات محددة',
                          primary: (
                            'فتح',
                            () => _go(const DoctorsServicesHomeScreen()),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final (String, VoidCallback) primary;

  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return NeuCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: .1),
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
          Flexible(
            child: Text(
              subtitle,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .65),
                fontSize: 13.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 10),
          NeuButton.primary(
            label: primary.$1,
            icon: Icons.open_in_new_rounded,
            onPressed: primary.$2,
          ),
        ],
      ),
    );
  }
}
