// lib/screens/returns/view_return_screen.dart
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/return_entry.dart';
import 'edit_return_screen.dart';

class ViewReturnScreen extends StatelessWidget {
  final ReturnEntry returnEntry;
  const ViewReturnScreen({super.key, required this.returnEntry});

  String _fmt2(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final dateOnly = DateFormat('yyyy-MM-dd');
    final timeOnly = DateFormat('HH:mm');

    final dateStr = dateOnly.format(returnEntry.date.toLocal());
    final timeStr = timeOnly.format(returnEntry.date.toLocal());

    String orDash(String s) => (s.trim().isEmpty) ? '—' : s;

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
          actions: [
            IconButton(
              tooltip: 'تعديل',
              icon: const Icon(Icons.edit_rounded),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EditReturnScreen(returnEntry: returnEntry),
                  ),
                );
              },
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
                children: [
                  const TSectionHeader('تفاصيل العودة'),

                  // التاريخ والوقت كبطاقات معلومات صغيرة
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      TInfoCard(
                        icon: Icons.calendar_month_rounded,
                        label: 'التاريخ',
                        value: dateStr,
                      ),
                      TInfoCard(
                        icon: Icons.access_time_rounded,
                        label: 'الوقت',
                        value: timeStr,
                      ),
                      TInfoCard(
                        icon: Icons.request_quote_outlined,
                        label: 'المبلغ المتبقي عليه',
                        value: _fmt2(returnEntry.remaining),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  const TSectionHeader('بيانات المريض'),

                  // بيانات رئيسية
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      TInfoCard(
                        icon: Icons.person_outline,
                        label: 'اسم المريض',
                        value: orDash(returnEntry.patientName),
                        maxLines: 1,
                      ),
                      TInfoCard(
                        icon: Icons.phone_iphone_rounded,
                        label: 'رقم الهاتف',
                        value: orDash(returnEntry.phoneNumber),
                        maxLines: 1,
                      ),
                      TInfoCard(
                        icon: Icons.badge_outlined,
                        label: 'العمر',
                        value: '${returnEntry.age}',
                        maxLines: 1,
                      ),
                      TInfoCard(
                        icon: Icons.local_hospital_outlined,
                        label: 'الطبيب',
                        value: orDash(returnEntry.doctor),
                        maxLines: 1,
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),
                  const TSectionHeader('تفاصيل الحالة'),

                  NeuCard(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Column(
                      children: [
                        NeuField(
                          labelText: 'حالة المريض',
                          controller: TextEditingController(
                            text: orDash(returnEntry.diagnosis),
                          ),
                          enabled: false,
                          maxLines: 3,
                        ),
                        const SizedBox(height: 10),
                        NeuField(
                          labelText: 'ملاحظات',
                          controller: TextEditingController(
                            text: orDash(returnEntry.notes),
                          ),
                          enabled: false,
                          maxLines: 4,
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // شريط سفلي ثابت للإجراءات
              Align(
                alignment: Alignment.bottomCenter,
                child: NeuCard(
                  margin: EdgeInsets.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Expanded(
                          child: TOutlinedButton(
                            icon: Icons.arrow_back_rounded,
                            label: 'رجوع',
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                        const SizedBox(width: 10),
                        NeuButton.primary(
                          label: 'تعديل',
                          icon: Icons.edit_rounded,
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    EditReturnScreen(returnEntry: returnEntry),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
