// lib/screens/returns/edit_return_screen.dart
import 'dart:ui' as ui show TextDirection;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'list_returns_screen.dart';

class EditReturnScreen extends StatefulWidget {
  final ReturnEntry returnEntry;
  const EditReturnScreen({super.key, required this.returnEntry});

  @override
  State<EditReturnScreen> createState() => _EditReturnScreenState();
}

class _EditReturnScreenState extends State<EditReturnScreen> {
  // التاريخ والوقت
  late DateTime _selectedDate;
  late TimeOfDay _selectedTime;

  // متحكمات النصوص
  final _patientNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _ageCtrl = TextEditingController(); // العمر (قراءة فقط)
  final _doctorCtrl = TextEditingController(); // الطبيب (قراءة فقط)
  final _diagnosisCtrl = TextEditingController(); // حالة المريض (قراءة فقط)
  final _remainingCtrl = TextEditingController(); // المبلغ المتبقي
  final _notesCtrl = TextEditingController(); // ملاحظات (تحرير)

  final _dateOnly = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.returnEntry.date;
    _selectedTime = TimeOfDay.fromDateTime(widget.returnEntry.date);

    _patientNameCtrl.text = widget.returnEntry.patientName;
    _phoneCtrl.text = widget.returnEntry.phoneNumber;
    _ageCtrl.text = widget.returnEntry.age.toString();
    _doctorCtrl.text = widget.returnEntry.doctor;
    _diagnosisCtrl.text = widget.returnEntry.diagnosis;
    _remainingCtrl.text = widget.returnEntry.remaining.toString();
    _notesCtrl.text = widget.returnEntry.notes;
  }

  @override
  void dispose() {
    _patientNameCtrl.dispose();
    _phoneCtrl.dispose();
    _ageCtrl.dispose();
    _doctorCtrl.dispose();
    _diagnosisCtrl.dispose();
    _remainingCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  DateTime _combineDateAndTime(DateTime d, TimeOfDay t) =>
      DateTime(d.year, d.month, d.day, t.hour, t.minute);

  Future<void> _pickDate() async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar'),
      helpText: 'اختر تاريخ العودة',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: scheme.copyWith(primary: kPrimaryColor),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      helpText: 'اختر وقت العودة',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          timePickerTheme: const TimePickerThemeData(),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedTime = picked);
  }

  Future<void> _updateReturn() async {
    final updatedDateTime = _combineDateAndTime(_selectedDate, _selectedTime);

    final updatedEntry = ReturnEntry(
      id: widget.returnEntry.id,
      date: updatedDateTime,
      patientName: _patientNameCtrl.text,
      phoneNumber: _phoneCtrl.text,
      diagnosis: _diagnosisCtrl.text,
      remaining: double.tryParse(_remainingCtrl.text) ?? 0.0,
      age: int.tryParse(_ageCtrl.text) ?? 0,
      doctor: _doctorCtrl.text,
      notes: _notesCtrl.text,
    );

    await DBService.instance.updateReturnEntry(updatedEntry);

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const ListReturnsScreen()),
    );
  }

  Future<void> _onSavePressed() async {
    await _updateReturn();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم تعديل بيانات العودة بنجاح.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
              tooltip: 'حفظ',
              icon: const Icon(Icons.check_rounded),
              onPressed: _onSavePressed,
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              RefreshIndicator(
                color: scheme.primary,
                onRefresh: () async => setState(() {}),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
                  children: [
                    // عنوان قسم
                    const _SectionHeader('تعديل بيانات العودة'),

                    // اختيار التاريخ والوقت بنمط TBIAN
                    Row(
                      children: [
                        Expanded(
                          child: TDateButton(
                            icon: Icons.calendar_month_rounded,
                            label: _dateOnly.format(_selectedDate),
                            onTap: _pickDate,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TDateButton(
                            icon: Icons.access_time_rounded,
                            label: _selectedTime.format(context),
                            onTap: _pickTime,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // حقول القراءة فقط (داخل NeuCard لتماسك الشكل)
                    NeuCard(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: Column(
                        children: [
                          NeuField(
                            controller: _patientNameCtrl,
                            labelText: 'اسم المريض',
                            enabled: false,
                          ),
                          const SizedBox(height: 10),
                          NeuField(
                            controller: _phoneCtrl,
                            labelText: 'رقم الهاتف',
                            enabled: false,
                          ),
                          const SizedBox(height: 10),
                          NeuField(
                            controller: _ageCtrl,
                            labelText: 'العمر',
                            enabled: false,
                          ),
                          const SizedBox(height: 10),
                          NeuField(
                            controller: _doctorCtrl,
                            labelText: 'الطبيب',
                            enabled: false,
                          ),
                          const SizedBox(height: 10),
                          NeuField(
                            controller: _diagnosisCtrl,
                            labelText: 'حالة المريض',
                            enabled: false,
                            maxLines: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // الحقول القابلة للتعديل
                    NeuCard(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      child: Column(
                        children: [
                          NeuField(
                            controller: _remainingCtrl,
                            labelText: 'المبلغ المتبقي عليه',
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true, signed: false),
                          ),
                          const SizedBox(height: 10),
                          NeuField(
                            controller: _notesCtrl,
                            labelText: 'ملاحظات',
                            maxLines: 3,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // شريط سفلي ثابت للإجراءات (حفظ/رجوع) بنمط TBIAN
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
                          label: 'حفظ',
                          icon: Icons.check_rounded,
                          onPressed: _onSavePressed,
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

/*──────── عنوان قسم متماسك مع TBIAN ────────*/
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w800,
          fontSize: 18,
        ),
      ),
    );
  }
}
