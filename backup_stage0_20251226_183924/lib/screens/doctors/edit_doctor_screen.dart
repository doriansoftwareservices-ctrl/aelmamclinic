// lib/screens/doctors/edit_doctor_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/services/db_service.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class EditDoctorScreen extends StatefulWidget {
  final Doctor doctor;

  const EditDoctorScreen({super.key, required this.doctor});

  @override
  State<EditDoctorScreen> createState() => _EditDoctorScreenState();
}

class _EditDoctorScreenState extends State<EditDoctorScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameCtrl;
  late TextEditingController _specializationCtrl;
  late TextEditingController _phoneCtrl;

  TimeOfDay? _startTime;
  TimeOfDay? _endTime;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.doctor.name);
    _specializationCtrl =
        TextEditingController(text: widget.doctor.specialization);
    _phoneCtrl = TextEditingController(text: widget.doctor.phoneNumber);
    _startTime = _parseTimeOfDay(widget.doctor.startTime);
    _endTime = _parseTimeOfDay(widget.doctor.endTime);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _specializationCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  TimeOfDay? _parseTimeOfDay(String s) {
    if (s.isEmpty) return null;
    final parts = s.split(':');
    if (parts.length != 2) return null;
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  String _formatTimeOfDay(TimeOfDay? time) {
    if (time == null) return 'غير محدد';
    final now = DateTime.now();
    final dt = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    return DateFormat('HH:mm').format(dt);
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay? initial) {
    return showTimePicker(
      context: context,
      initialTime: initial ?? TimeOfDay.now(),
    );
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;

    final updated = Doctor(
      id: widget.doctor.id,
      employeeId: widget.doctor.employeeId,
      userUid: widget.doctor.userUid,
      name: _nameCtrl.text.trim(),
      specialization: _specializationCtrl.text.trim(),
      phoneNumber: _phoneCtrl.text.trim(),
      startTime: _formatTimeOfDay(_startTime),
      endTime: _formatTimeOfDay(_endTime),
    );

    await DBService.instance.updateDoctor(updated);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم تحديث ساعات المناوبة')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
            const Text('تعديل بيانات الطبيب'),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                // بيانات الطبيب (عرض فقط)
                NeuField(
                  controller: _nameCtrl,
                  labelText: 'اسم الطبيب',
                  enabled: false,
                  prefix: const Icon(Icons.badge_rounded),
                ),
                const SizedBox(height: 10),
                NeuField(
                  controller: _specializationCtrl,
                  labelText: 'التخصص',
                  enabled: false,
                  prefix: const Icon(Icons.work_rounded),
                ),
                const SizedBox(height: 10),
                NeuField(
                  controller: _phoneCtrl,
                  labelText: 'رقم الهاتف',
                  enabled: false,
                  prefix: const Icon(Icons.call_rounded),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 14),

                // ساعات المناوبة (من)
                NeuCard(
                  onTap: () async {
                    final picked = await _pickTime(_startTime);
                    if (picked != null) setState(() => _startTime = picked);
                  },
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.schedule_rounded,
                        color: kPrimaryColor.withValues(alpha: .9)),
                    title: const Text(
                      'ساعات المناوبة (من)',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    subtitle: Text(
                      _formatTimeOfDay(_startTime),
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_left_rounded),
                  ),
                ),
                const SizedBox(height: 10),

                // ساعات المناوبة (إلى)
                NeuCard(
                  onTap: () async {
                    final picked = await _pickTime(_endTime);
                    if (picked != null) setState(() => _endTime = picked);
                  },
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.access_time_filled_rounded,
                        color: kPrimaryColor.withValues(alpha: .9)),
                    title: const Text(
                      'ساعات المناوبة (إلى)',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                    subtitle: Text(
                      _formatTimeOfDay(_endTime),
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: .7),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_left_rounded),
                  ),
                ),

                const SizedBox(height: 20),

                // زر الحفظ
                Align(
                  alignment: Alignment.centerRight,
                  child: NeuButton.primary(
                    label: 'حفظ التعديلات',
                    icon: Icons.save_rounded,
                    onPressed: _saveChanges,
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
