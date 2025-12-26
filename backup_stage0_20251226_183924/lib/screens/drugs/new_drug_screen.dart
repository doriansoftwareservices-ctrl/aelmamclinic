// lib/screens/drugs/new_drug_screen.dart
import 'package:flutter/material.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/validators.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/models/drug.dart';

class NewDrugScreen extends StatefulWidget {
  final Drug? initialDrug; // إن كانت موجودة → وضع تعديل

  const NewDrugScreen({super.key, this.initialDrug});

  @override
  State<NewDrugScreen> createState() => _NewDrugScreenState();
}

class _NewDrugScreenState extends State<NewDrugScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _saving = false;

  // كاش بسيط لهيكل الجدول لتجنب تكرار PRAGMA
  Set<String>? _drugCols;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDrug;
    if (d != null) {
      _nameCtrl.text = d.name;
      _notesCtrl.text = d.notes ?? '';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<Set<String>> _getDrugColumns() async {
    if (_drugCols != null) return _drugCols!;
    final db = await DBService.instance.database;
    final rows = await db.rawQuery('PRAGMA table_info(drugs)');
    _drugCols = rows.map((r) => (r['name'] as String)).toSet();
    return _drugCols!;
  }

  Future<bool> _hasColumn(String name) async {
    final cols = await _getDrugColumns();
    return cols.contains(name);
  }

  Future<bool> _isDuplicateName(String name) async {
    final db = await DBService.instance.database;
    final lower = name.trim().toLowerCase();
    final hasIsDeleted = await _hasColumn('isDeleted');

    final whereBuffer = StringBuffer('LOWER(name) = ?');
    final whereArgs = <Object?>[lower];

    if (widget.initialDrug != null) {
      whereBuffer.write(' AND id != ?');
      whereArgs.add(widget.initialDrug!.id);
    }
    if (hasIsDeleted) {
      whereBuffer.write(' AND IFNULL(isDeleted,0)=0');
    }

    final rows = await db.query(
      'drugs',
      columns: const ['id'],
      where: whereBuffer.toString(),
      whereArgs: whereArgs,
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameCtrl.text.trim();
    final rawNotes = _notesCtrl.text.trim();
    final notes = rawNotes.isEmpty ? null : rawNotes;

    // تحقق من التكرار (يتجاهل المحذوف منطقياً إن وُجد)
    if (await _isDuplicateName(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اسم الدواء موجود مسبقًا')),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _saving = true);

    try {
      final db = await DBService.instance.database;
      final nowIso = DateTime.now().toIso8601String();

      // نبني الـ payload مع احترام أعمدة الجدول الفعلية
      final hasCreatedAtCamel = await _hasColumn('createdAt');
      final hasCreatedAtSnake = await _hasColumn('created_at');

      final insertMap = <String, Object?>{
        'name': name,
        if (notes != null) 'notes': notes,
        if (widget.initialDrug == null && hasCreatedAtCamel)
          'createdAt': nowIso,
        if (widget.initialDrug == null && hasCreatedAtSnake)
          'created_at': nowIso,
      };

      await db.transaction((txn) async {
        if (widget.initialDrug == null) {
          // إضافة
          await txn.insert('drugs', insertMap);
        } else {
          // تعديل
          final updateMap = <String, Object?>{'name': name};
          if (await _hasColumn('notes')) updateMap['notes'] = notes;
          await txn.update(
            'drugs',
            updateMap,
            where: 'id = ?',
            whereArgs: [widget.initialDrug!.id],
          );
        }
      });

      // لو الـ Sync متصل، هذا سيطلق دفعًا فوريًا (إن كان onLocalChange معيّنًا).
      try {
        await DBService.instance.onLocalChange?.call('drugs');
      } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.initialDrug == null
              ? 'تم إضافة الدواء'
              : 'تم تحديث بيانات الدواء'),
        ),
      );

      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ أثناء الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initialDrug != null;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.medication_rounded),
              const SizedBox(width: 8),
              Text(isEdit ? 'تعديل بيانات الدواء' : 'إضافة دواء جديد'),
            ],
          ),
          // ✅ تمت إزالة زر "تشخيص"
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Form(
              key: _formKey,
              child: ListView(
                children: [
                  // الاسم
                  NeuField(
                    controller: _nameCtrl,
                    labelText: 'اسم الدواء',
                    hintText: 'ادخل اسم الدواء',
                    prefix: const Icon(Icons.label_important_outline_rounded),
                    validator: (v) =>
                        Validators.required(v, fieldName: 'اسم الدواء'),
                  ),
                  const SizedBox(height: 12),

                  // الملاحظات
                  NeuField(
                    controller: _notesCtrl,
                    labelText: 'ملاحظات (اختياري)',
                    hintText: 'أدخل أي ملاحظات',
                    prefix: const Icon(Icons.notes_rounded),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 20),

                  // زر الحفظ
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.save_rounded),
                      label: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
