// lib/screens/returns/new_return_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'list_returns_screen.dart';

class NewReturnScreen extends StatefulWidget {
  const NewReturnScreen({super.key});

  @override
  State<NewReturnScreen> createState() => _NewReturnScreenState();
}

class _NewReturnScreenState extends State<NewReturnScreen> {
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();

  final _patientNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _doctorCtrl = TextEditingController();
  final _diagnosisCtrl = TextEditingController();
  final _remainingCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  final _dateOnly = DateFormat('yyyy-MM-dd');

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
    final d = await showDatePicker(
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
    if (d != null) setState(() => _selectedDate = d);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      helpText: 'اختر وقت العودة',
    );
    if (t != null) setState(() => _selectedTime = t);
  }

  Future<void> _onSavePressed() async {
    // منع الحفظ بدون اختيار مريض
    if (_patientNameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء اختيار مريض أولًا.')),
      );
      return;
    }

    final now = DateTime.now();
    final selectedDateOnly =
        DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    final nowDateOnly = DateTime(now.year, now.month, now.day);

    if (selectedDateOnly.isBefore(nowDateOnly) ||
        selectedDateOnly.isAtSameMomentAs(nowDateOnly)) {
      final ok = await _confirmPastOrToday();
      if (!ok) return;
    }

    try {
      await _saveReturn();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('تم حفظ معلومات العودة بنجاح.'),
            duration: Duration(seconds: 2)),
      );
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ListReturnsScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل حفظ العودة: $e')),
      );
    }
  }

  Future<bool> _confirmPastOrToday() async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد الحفظ'),
        content: const Text(
            'التاريخ المحدد هو اليوم أو تاريخ ماضٍ. هل تريد بالفعل حفظ بيانات العودة لهذا التاريخ؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimaryColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تأكيد', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  Future<void> _saveReturn() async {
    final dt = _combineDateAndTime(_selectedDate, _selectedTime);

    final entry = ReturnEntry(
      date: dt,
      patientName: _patientNameCtrl.text.trim(),
      phoneNumber: _phoneCtrl.text.trim(),
      diagnosis: _diagnosisCtrl.text.trim(),
      remaining: double.tryParse(_remainingCtrl.text.trim()) ?? 0.0,
      age: int.tryParse(_ageCtrl.text.trim()) ?? 0,
      doctor: _doctorCtrl.text.trim(),
      notes: _notesCtrl.text.trim(),
    );

    await DBService.instance.insertReturnEntry(entry);
  }

  Future<void> _selectPatient() async {
    final selected = await showModalBottomSheet<Patient>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const _PatientSearchSheet(),
    );
    if (selected != null) {
      _patientNameCtrl.text = selected.name;
      _phoneCtrl.text = selected.phoneNumber.trim();
      _diagnosisCtrl.text = selected.diagnosis.trim();
      _ageCtrl.text = selected.age.toString();
      _doctorCtrl.text = (selected.doctorName ?? '').trim();
    }
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
                    const TSectionHeader('إنشاء عودة'),

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

                    // اختيار المريض + حقول القراءة فقط
                    NeuCard(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: Column(
                        children: [
                          // ✅ جعل كامل الحقل قابلًا للنقر لفتح قائمة المرضى
                          InkWell(
                            onTap: _selectPatient,
                            borderRadius: BorderRadius.circular(14),
                            child: AbsorbPointer(
                              // لماذا AbsorbPointer؟ لمنع تحرير النص مع الإبقاء على شكل الحقل
                              child: NeuField(
                                controller: _patientNameCtrl,
                                labelText: 'اسم المريض',
                                hintText: 'اضغط للاختيار…',
                                // الأيقونة للزينة فقط؛ النقر أصبح على كامل الحقل
                                suffix: const Icon(Icons.person_search_rounded),
                              ),
                            ),
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

/*──────── BottomSheet: البحث عن مريض (أسلوب TBIAN) ────────*/
class _PatientSearchSheet extends StatefulWidget {
  const _PatientSearchSheet();

  @override
  State<_PatientSearchSheet> createState() => _PatientSearchSheetState();
}

class _PatientSearchSheetState extends State<_PatientSearchSheet> {
  final _searchCtrl = TextEditingController();
  List<Patient> _all = [];
  List<Patient> _filtered = [];

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => _apply(_searchCtrl.text));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await DBService.instance.getAllPatients();
    if (!mounted) return; // حماية عند الإغلاق السريع
    setState(() {
      _all = list;
      _filtered = list;
    });
  }

  void _apply(String v) {
    final q = v.toLowerCase().trim();
    setState(() {
      _filtered = _all.where((p) {
        final name = (p.name).toLowerCase();
        final phone = p.phoneNumber.toLowerCase();
        return q.isEmpty || name.contains(q) || phone.contains(q);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (ctx, scrollController) {
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // شريط البحث بنمط TBIAN
                  TSearchField(
                    controller: _searchCtrl,
                    hint: 'ابحث عن اسم أو هاتف المريض…',
                    onChanged: (_) {},
                    onClear: () {
                      _searchCtrl.clear();
                      _apply('');
                    },
                  ),
                  const SizedBox(height: 10),

                  // النتائج
                  Expanded(
                    child: _filtered.isEmpty
                        ? const Center(child: Text('لا توجد نتائج'))
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: _filtered.length,
                            itemBuilder: (_, i) {
                              final p = _filtered[i];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: NeuCard(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  onTap: () => Navigator.pop(context, p),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 6),
                                    leading: Container(
                                      decoration: BoxDecoration(
                                        color: kPrimaryColor.withValues(
                                            alpha: .10),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      padding: const EdgeInsets.all(8),
                                      child: const Icon(Icons.person_outline,
                                          color: kPrimaryColor, size: 20),
                                    ),
                                    title: Text(
                                      p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800),
                                    ),
                                    subtitle: Text(
                                      'هاتف: ${p.phoneNumber.isEmpty ? '—' : p.phoneNumber}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: scheme.onSurface
                                              .withValues(alpha: .75)),
                                    ),
                                    trailing:
                                        const Icon(Icons.chevron_left_rounded),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
