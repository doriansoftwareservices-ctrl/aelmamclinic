// lib/screens/prescriptions/new_prescription_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/models/drug.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/screens/patients/patient_picker_screen.dart';

/* تصميم TBIAN */
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

/// عنصر دواء داخل الوصفة
class _RxItem {
  final int drugId;
  final String drugName;
  int days;
  int timesPerDay;

  _RxItem({
    required this.drugId,
    required this.drugName,
    required this.days,
    required this.timesPerDay,
  });
}

class NewPrescriptionScreen extends StatefulWidget {
  /// عند تمرير كائن ‎Patient تُملأ البيانات تلقائيًا
  final Patient? patient;

  /// إن مرّرنا ‎prescriptionId نفتح الوصفة للتعديل
  final int? prescriptionId;

  const NewPrescriptionScreen({
    super.key,
    this.patient,
    this.prescriptionId,
  });

  @override
  State<NewPrescriptionScreen> createState() => _NewPrescriptionScreenState();
}

class _NewPrescriptionScreenState extends State<NewPrescriptionScreen> {
  /*──────── بيانات أساسية ────────*/
  int? _patientId;
  String? _patientName;
  int? _doctorId;
  String? _doctorName;

  DateTime _recordDate = DateTime.now();

  final _drugSearch = TextEditingController();
  late List<Drug> _allDrugs;
  late List<Drug> _filteredDrugs;

  final List<_RxItem> _items = [];

  bool _loading = true;
  bool _saving = false;

  final _dateFmt = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _patientId = widget.patient?.id;
    _patientName = widget.patient?.name;
    _init();
  }

  Future<void> _init() async {
    _allDrugs = await DBService.instance.getAllDrugs();
    _filteredDrugs = _allDrugs;

    if (widget.prescriptionId != null) {
      await _loadExisting(widget.prescriptionId!);
    }

    if (mounted) setState(() => _loading = false);
  }

  /*──────── تحميل وصفة موجودة ─────────*/
  Future<void> _loadExisting(int id) async {
    final db = await DBService.instance.database;

    final head = await db.query('prescriptions',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (head.isEmpty) return;
    final h = head.first;

    _patientId = h['patientId'] as int;
    _recordDate = DateTime.parse(h['recordDate'] as String);
    _doctorId = h['doctorId'] as int?;

    if (_doctorId != null) {
      final d = await db.query('doctors',
          where: 'id = ?', whereArgs: [_doctorId], limit: 1);
      if (d.isNotEmpty) _doctorName = 'د/${d.first['name']}';
    }

    final p = await db.query('patients',
        where: 'id = ?', whereArgs: [_patientId], limit: 1);
    if (p.isNotEmpty) _patientName = p.first['name'] as String;

    final rows = await db.rawQuery('''
      SELECT pi.*, d.name AS drugName
      FROM prescription_items pi
      JOIN drugs d ON d.id = pi.drugId
      WHERE pi.prescriptionId = ?
    ''', [id]);

    _items
      ..clear()
      ..addAll(rows.map((r) => _RxItem(
            drugId: r['drugId'] as int,
            drugName: r['drugName'] as String,
            days: r['days'] as int,
            timesPerDay: r['timesPerDay'] as int,
          )));
  }

  /*──────── اختيار المريض ────────*/
  Future<void> _selectPatient() async {
    final sel = await Navigator.push<Patient?>(
      context,
      MaterialPageRoute(builder: (_) => const PatientPickerScreen()),
    );
    if (sel != null) {
      setState(() {
        _patientId = sel.id;
        _patientName = sel.name;
      });
    }
  }

  /*──────── اختيار الطبيب ────────*/
  Future<void> _selectDoctor() async {
    final list = await DBService.instance.getAllDoctors();
    List<Doctor> showing = List.from(list);

    final scheme = Theme.of(context).colorScheme;
    final chosen = await showDialog<Doctor>(
      context: context,
      builder: (ctx) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx)
              .colorScheme
              .copyWith(primary: scheme.primary, surface: scheme.surface),
        ),
        child: StatefulBuilder(
          builder: (c2, setDlg) => AlertDialog(
            title: const Text('اختر الطبيب'),
            content: SizedBox(
              width: double.maxFinite,
              height: 320,
              child: Column(
                children: [
                  NeuField(
                    labelText: 'بحث...',
                    prefix: const Icon(Icons.search),
                    onChanged: (v) => setDlg(() {
                      showing = list
                          .where((d) =>
                              d.name.toLowerCase().contains(v.toLowerCase()))
                          .toList();
                    }),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: showing.isEmpty
                        ? const Center(child: Text('لا يوجد نتائج'))
                        : ListView.builder(
                            itemCount: showing.length,
                            itemBuilder: (_, i) {
                              final d = showing[i];
                              return ListTile(
                                title: Text('د/${d.name}'),
                                subtitle: Text(d.specialization),
                                onTap: () => Navigator.pop(ctx, d),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('إغلاق')),
            ],
          ),
        ),
      ),
    );

    if (chosen != null) {
      setState(() {
        _doctorId = chosen.id;
        _doctorName = 'د/${chosen.name}';
      });
    }
  }

  /*──────── إضافة/تعديل عنصر دواء ────────*/
  Future<void> _addDrug() async {
    _filteredDrugs = _allDrugs;
    _drugSearch.clear();

    final scheme = Theme.of(context).colorScheme;
    final Drug? drug = await showDialog<Drug>(
      context: context,
      builder: (ctx) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx)
              .colorScheme
              .copyWith(primary: scheme.primary, surface: scheme.surface),
        ),
        child: StatefulBuilder(
          builder: (c2, setDlg) => AlertDialog(
            title: const Text('اختر دواء'),
            content: SizedBox(
              width: double.maxFinite,
              height: 360,
              child: Column(
                children: [
                  NeuField(
                    controller: _drugSearch,
                    labelText: 'بحث بالاسم',
                    prefix: const Icon(Icons.search),
                    onChanged: (v) => setDlg(() {
                      _filteredDrugs = _allDrugs
                          .where((d) =>
                              d.name.toLowerCase().contains(v.toLowerCase()))
                          .toList();
                    }),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _filteredDrugs.isEmpty
                        ? const Center(child: Text('لا نتائج'))
                        : ListView.builder(
                            itemCount: _filteredDrugs.length,
                            itemBuilder: (_, i) {
                              final d = _filteredDrugs[i];
                              return ListTile(
                                title: Text(d.name),
                                onTap: () => Navigator.pop(ctx, d),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (drug == null) return;

    await _editItemDialog(
      title: drug.name,
      initialDays: null,
      initialTimes: null,
      onSave: (days, times) {
        setState(() {
          _items.add(_RxItem(
            drugId: drug.id!,
            drugName: drug.name,
            days: days,
            timesPerDay: times,
          ));
        });
      },
    );
  }

  Future<void> _editItem(_RxItem item) async {
    await _editItemDialog(
      title: item.drugName,
      initialDays: item.days,
      initialTimes: item.timesPerDay,
      onSave: (days, times) {
        setState(() {
          item.days = days;
          item.timesPerDay = times;
        });
      },
    );
  }

  Future<void> _editItemDialog({
    required String title,
    int? initialDays,
    int? initialTimes,
    required void Function(int days, int timesPerDay) onSave,
  }) async {
    final daysCtrl = TextEditingController(text: initialDays?.toString() ?? '');
    final timesCtrl =
        TextEditingController(text: initialTimes?.toString() ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeuField(
                controller: daysCtrl,
                labelText: 'عدد أيام الاستخدام',
                keyboardType: const TextInputType.numberWithOptions(
                    signed: false, decimal: false),
                textDirection: ui.TextDirection.ltr,
                textAlign: TextAlign.center,
                prefix: const Icon(Icons.calendar_today_rounded),
              ),
              const SizedBox(height: 10),
              NeuField(
                controller: timesCtrl,
                labelText: 'مرات الاستخدام في اليوم',
                keyboardType: const TextInputType.numberWithOptions(
                    signed: false, decimal: false),
                textDirection: ui.TextDirection.ltr,
                textAlign: TextAlign.center,
                prefix: const Icon(Icons.schedule_rounded),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      final d = int.tryParse(daysCtrl.text) ?? 0;
      final t = int.tryParse(timesCtrl.text) ?? 0;
      if (d <= 0 || t <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إدخال قيم صحيحة (> 0)')),
        );
        return;
      }
      onSave(d, t);
    }
  }

  /*──────── الحفظ ────────*/
  Future<void> _save() async {
    if (_patientId == null || _items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('اختر المريض وأضف دواءً واحداً على الأقل')),
      );
      return;
    }
    setState(() => _saving = true);

    final db = await DBService.instance.database;

    if (widget.prescriptionId == null) {
      final headId = await db.insert('prescriptions', {
        'patientId': _patientId,
        'doctorId': _doctorId,
        'recordDate': _recordDate.toIso8601String(),
        'createdAt': DateTime.now().toIso8601String(),
      });

      final batch = db.batch();
      for (final it in _items) {
        batch.insert('prescription_items', {
          'prescriptionId': headId,
          'drugId': it.drugId,
          'days': it.days,
          'timesPerDay': it.timesPerDay,
        });
      }
      await batch.commit(noResult: true);
    } else {
      await db.update(
        'prescriptions',
        {
          'patientId': _patientId,
          'doctorId': _doctorId,
          'recordDate': _recordDate.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [widget.prescriptionId],
      );

      await db.delete('prescription_items',
          where: 'prescriptionId = ?', whereArgs: [widget.prescriptionId]);

      final batch = db.batch();
      for (final it in _items) {
        batch.insert('prescription_items', {
          'prescriptionId': widget.prescriptionId,
          'drugId': it.drugId,
          'days': it.days,
          'timesPerDay': it.timesPerDay,
        });
      }
      await batch.commit(noResult: true);
    }

    setState(() => _saving = false);
    if (mounted) Navigator.pop(context);
  }

  int get _totalDoses =>
      _items.fold(0, (s, it) => s + (it.days * it.timesPerDay));

  /*──────────────────────── الواجهة ─────────────────────────*/
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title:
              Text(widget.prescriptionId == null ? 'إنشاء وصفة' : 'تعديل وصفة'),
          actions: [
            if (widget.prescriptionId != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: Center(
                  child: Text(
                    _dateFmt.format(_recordDate),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ),
        body: AbsorbPointer(
          absorbing: _saving,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                /*── المريض ───────────────────────────────*/
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  onTap: _selectPatient,
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.person,
                            color: kPrimaryColor, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _patientName ?? 'اختر المريض',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Icon(Icons.chevron_left_rounded,
                          color: scheme.onSurface.withValues(alpha: .6)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                /*── الطبيب ───────────────────────────────*/
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  onTap: _selectDoctor,
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.local_hospital,
                            color: kPrimaryColor, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _doctorName ?? 'اختر الطبيب',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Icon(Icons.chevron_left_rounded,
                          color: scheme.onSurface.withValues(alpha: .6)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                /*── التاريخ ─────────────────────────────*/
                NeuCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _recordDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      builder: (ctx, child) => Theme(
                        data: Theme.of(ctx).copyWith(
                          colorScheme: Theme.of(ctx)
                              .colorScheme
                              .copyWith(primary: scheme.primary),
                        ),
                        child: child!,
                      ),
                    );
                    if (d != null) setState(() => _recordDate = d);
                  },
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.calendar_month,
                            color: kPrimaryColor, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _dateFmt.format(_recordDate),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Icon(Icons.chevron_left_rounded,
                          color: scheme.onSurface.withValues(alpha: .6)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                /*── الأدوية المختارة ─────────────────────*/
                if (_items.isNotEmpty) ...[
                  const TSectionHeader('الأدوية المختارة'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _items
                        .map(
                          (it) => InputChip(
                            backgroundColor:
                                kPrimaryColor.withValues(alpha: .08),
                            label: Text(
                                '${it.drugName} • ${it.days} يوم × ${it.timesPerDay}'),
                            onDeleted: () => setState(() => _items.remove(it)),
                            onPressed: () => _editItem(it),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                  const TSectionHeader('ملخص'),
                  TInfoCard(
                    icon: Icons.medication_liquid_rounded,
                    label: 'إجمالي الجرعات',
                    value: '$_totalDoses',
                  ),
                  const SizedBox(height: 16),
                ],

                /*── زر إضافة دواء ───────────────────────*/
                NeuButton.flat(
                  icon: Icons.add_rounded,
                  label: 'إضافة دواء',
                  onPressed: _addDrug,
                ),
                const SizedBox(height: 24),

                /*── زر الحفظ ───────────────────────────*/
                if (_saving)
                  const Center(child: CircularProgressIndicator())
                else
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.save),
                      label: const Text('حفظ'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        padding: const EdgeInsets.symmetric(
                            vertical: 12, horizontal: 16),
                      ),
                      onPressed: _save,
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
