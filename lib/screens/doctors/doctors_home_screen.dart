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
import 'package:aelmamclinic/widgets/feature_hub.dart';

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
                child: FeatureHubBody(
                  title: 'إدارة الأطباء',
                  items: [
                    FeatureHubItem(
                      icon: Icons.person_add_alt_1_rounded,
                      title: 'إضافة طبيب',
                      subtitle:
                          'تسجيل طبيب جديد مع البيانات الأساسية ونسب الخدمات لاحقاً',
                      onTap: () => _go(const NewDoctorScreen()),
                    ),
                    FeatureHubItem(
                      icon: Icons.list_alt_rounded,
                      title: 'قائمة الأطباء',
                      subtitle:
                          'استعراض وتعديل بيانات الأطباء الحاليين في العيادة',
                      onTap: () => _go(const ListDoctorsScreen()),
                    ),
                    FeatureHubItem(
                      icon: Icons.people_alt_rounded,
                      title: 'مرضى الأطباء',
                      subtitle: 'عرض المرضى المرتبطين بالأطباء مع تفاصيل الخدمة',
                      onTap: () => _go(const DoctorsPatientsScreen()),
                    ),
                    FeatureHubItem(
                      icon: Icons.medical_services_rounded,
                      title: 'قوائم خدمات الأطباء',
                      subtitle: 'تحديد نسب الطبيب ونسبة المركز لخدمات محددة',
                      onTap: () => _go(const DoctorsServicesHomeScreen()),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
