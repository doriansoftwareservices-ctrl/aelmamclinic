// lib/screens/doctors/view_doctor_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' as ui show TextDirection;
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

import 'package:aelmamclinic/models/doctor.dart';
import 'edit_doctor_screen.dart';

class ViewDoctorScreen extends StatelessWidget {
  final Doctor doctor;
  const ViewDoctorScreen({super.key, required this.doctor});

  String _val(String s) => (s.isEmpty) ? 'غير محدد' : s;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.badge_rounded),
              SizedBox(width: 8),
              Text('بيانات الطبيب'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => EditDoctorScreen(doctor: doctor)),
            );
          },
          icon: const Icon(Icons.edit_rounded),
          label: const Text('تعديل'),
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Column(
              children: [
                // بطاقة عنوانية لطيفة
                NeuCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(14),
                        child: const Icon(Icons.person_outline_rounded,
                            color: kPrimaryColor, size: 28),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('د/ ${doctor.name}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 16)),
                            const SizedBox(height: 2),
                            Text(
                              doctor.specialization,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: .7),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // تفاصيل قابلة للنسخ (قراءة فقط)
                Expanded(
                  child: ListView(
                    children: [
                      _InfoRow(
                        icon: Icons.local_hospital_outlined,
                        label: 'التخصص',
                        value: _val(doctor.specialization),
                      ),
                      const SizedBox(height: 8),
                      _InfoRow(
                        icon: Icons.phone_rounded,
                        label: 'رقم الهاتف',
                        value: _val(doctor.phoneNumber),
                        trailing: IconButton(
                          tooltip: 'نسخ',
                          icon: const Icon(Icons.copy_rounded),
                          onPressed: () {
                            if (doctor.phoneNumber.isEmpty) return;
                            Clipboard.setData(
                                ClipboardData(text: doctor.phoneNumber));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('تم نسخ رقم الهاتف')),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      _InfoRow(
                        icon: Icons.login_rounded,
                        label: 'ساعات المناوبة (من)',
                        value: _val(doctor.startTime),
                      ),
                      const SizedBox(height: 8),
                      _InfoRow(
                        icon: Icons.logout_rounded,
                        label: 'ساعات المناوبة (إلى)',
                        value: _val(doctor.endTime),
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

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: kPrimaryColor),
        ),
        title: Text(
          label,
          style: TextStyle(
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        trailing: trailing,
      ),
    );
  }
}
