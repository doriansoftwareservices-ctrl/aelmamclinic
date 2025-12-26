// lib/screens/appointments/advanced_booking_screen.dart

import 'package:flutter/material.dart';

import 'package:aelmamclinic/models/appointment.dart';
import 'package:aelmamclinic/services/db_service.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class AdvancedBookingScreen extends StatefulWidget {
  final Appointment? appointment; // عند التعديل

  const AdvancedBookingScreen({super.key, this.appointment});

  @override
  _AdvancedBookingScreenState createState() => _AdvancedBookingScreenState();
}

class _AdvancedBookingScreenState extends State<AdvancedBookingScreen> {
  final _formKey = GlobalKey<FormState>();
  late DateTime _selectedDate;
  late String _status;
  late String _notes;
  late int _patientId;

  @override
  void initState() {
    super.initState();
    if (widget.appointment != null) {
      _selectedDate = widget.appointment!.appointmentTime;
      _status = widget.appointment!.status;
      _notes = widget.appointment!.notes;
      _patientId = widget.appointment!.patientId;
    } else {
      _selectedDate = DateTime.now().add(const Duration(hours: 1));
      _status = "مؤكد";
      _notes = "";
      _patientId = 0; // يجب تحديده من شاشة اختيار المريض
    }
  }

  Future<void> _saveAppointment() async {
    if (_formKey.currentState!.validate()) {
      _formKey.currentState!.save();
      final newAppointment = Appointment(
        id: widget.appointment?.id,
        patientId: _patientId,
        appointmentTime: _selectedDate,
        status: _status,
        notes: _notes,
      );
      await DBService.instance.saveAppointment(newAppointment);
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
      builder: (ctx, child) {
        final scheme = Theme.of(ctx).colorScheme;
        return Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: scheme.copyWith(primary: kPrimaryColor),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      final TimeOfDay? time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_selectedDate),
        builder: (ctx, child) {
          final scheme = Theme.of(ctx).colorScheme;
          return Theme(
            data: Theme.of(ctx).copyWith(
              colorScheme: scheme.copyWith(primary: kPrimaryColor),
            ),
            child: child!,
          );
        },
      );
      if (time != null) {
        setState(() {
          _selectedDate = DateTime(
            picked.year,
            picked.month,
            picked.day,
            time.hour,
            time.minute,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.appointment != null ? 'تعديل الموعد' : 'حجز موعد جديد';

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
            Text(title),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                // بطاقة اختيار التاريخ/الوقت
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: ListTile(
                    onTap: _selectDate,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    title: Text(
                      "تاريخ ووقت الموعد: ${_selectedDate.toLocal()}",
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    trailing: Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: const Icon(Icons.calendar_today_rounded,
                          color: kPrimaryColor),
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                // الملاحظات
                NeuField(
                  controller: TextEditingController(text: _notes),
                  labelText: 'ملاحظات',
                  maxLines: 3,
                  prefix: const Icon(Icons.sticky_note_2_outlined),
                  onChanged: (v) => _notes = v,
                ),

                const SizedBox(height: 14),

                // حالة الموعد (Dropdown) ضمن حاوية نيومورفيزم
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(kRadius),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: .9),
                        offset: const Offset(-6, -6),
                        blurRadius: 12,
                      ),
                      BoxShadow(
                        color: const Color(0xFFCFD8DC).withValues(alpha: .6),
                        offset: const Offset(6, 6),
                        blurRadius: 14,
                      ),
                    ],
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  child: DropdownButtonFormField<String>(
                    value: _status,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      labelText: 'حالة الموعد',
                    ),
                    icon: const Icon(Icons.expand_more_rounded),
                    items: const [
                      DropdownMenuItem(value: "مؤكد", child: Text("مؤكد")),
                      DropdownMenuItem(value: "ملغى", child: Text("ملغى")),
                      DropdownMenuItem(
                          value: "تم التعديل", child: Text("تم التعديل")),
                    ],
                    onChanged: (value) => setState(() => _status = value!),
                  ),
                ),

                const Spacer(),

                // زر الحفظ (نيومورفيزم)
                Align(
                  alignment: Alignment.centerRight,
                  child: NeuButton.primary(
                    label: 'حفظ الموعد',
                    icon: Icons.save_rounded,
                    onPressed: _saveAppointment,
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
