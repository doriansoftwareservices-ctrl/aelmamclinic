// lib/screens/repository/items/add_item_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:excel/excel.dart' as xls;

import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';

/*──────── لوحة ألوان TBIAN الموحدة ────────*/
const Color accentColor = Color(0xFF004A61);
const Color lightAccentColor = Color(0xFF9ED9E6);
const Color veryLightBg = Color(0xFFF7F9F9);

class AddItemScreen extends StatefulWidget {
  const AddItemScreen({super.key});

  static const routeName = '/repository/items/add';

  @override
  State<AddItemScreen> createState() => _AddItemScreenState();
}

class _AddItemScreenState extends State<AddItemScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _stockCtrl = TextEditingController(text: '0');

  final _nameNode = FocusNode();
  final _stockNode = FocusNode();

  ItemType? _selectedType;
  bool _isSaving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _stockCtrl.dispose();
    _nameNode.dispose();
    _stockNode.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label, {Widget? prefixIcon, Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: Colors.white,
      prefixIcon: prefixIcon,
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(25),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(25),
        borderSide: BorderSide(color: accentColor.withValues(alpha: .35)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(25),
        borderSide: const BorderSide(color: accentColor, width: 2),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _selectedType == null) {
      if (_selectedType == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اختر نوع الصنف')),
        );
      }
      return;
    }
    setState(() => _isSaving = true);
    try {
      final stock = int.parse(_stockCtrl.text);
      await context.read<RepositoryProvider>().addItem(
            typeId: _selectedType!.id!,
            name: _nameCtrl.text.trim(),
            price: 0,
            initialStock: stock,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ الصنف بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ أثناء الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _createNewType() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إنشاء نوع صنف جديد'),
        content: TextFormField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'اسم النوع'),
          autofocus: true,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) =>
              Navigator.pop(ctx, ctrl.text.trim().isNotEmpty),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isNotEmpty),
              child: const Text('إنشاء')),
        ],
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      final name = ctrl.text.trim();
      final repo = context.read<RepositoryProvider>();
      await repo.addType(name);
      if (!mounted) return;
      // اضبط النوع المختار على النوع الذي أضيف للتو (بأمان)
      final match = repo.types.firstWhere(
        (t) => t.name.trim().toLowerCase() == name.toLowerCase(),
        orElse: () => repo.types.isNotEmpty ? repo.types.last : ItemType(name: name),
      );
      setState(() => _selectedType = match);
      // وضع التركيز مباشرة على اسم الصنف
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      _nameNode.requestFocus();
    }
  }

  /// استيراد أصناف من ملف Excel (عمود A: نوع الصنف، عمود B: اسم الصنف)
  Future<void> _importItemsFromExcel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xls'],
      withData: true,
    );
    if (result == null) return;
    final picked = result.files.single;
    if (picked.bytes == null && picked.path == null) return;

    try {
      final bytes =
          picked.bytes ?? await File(picked.path!).readAsBytes();
      if (!mounted) return;
      final excel = xls.Excel.decodeBytes(bytes);

      final repo = context.read<RepositoryProvider>();
      if (repo.types.isEmpty) {
        await repo.bootstrap();
      }
      final typesMap = {
        for (final t in repo.types) t.name.trim().toLowerCase(): t
      };
      final existingKeys =
          repo.allItems.map((it) => '${it.typeId}__${it.name.trim()}').toSet();

      int imported = 0;
      int skipped = 0;

      for (final sheetName in excel.tables.keys) {
        final sheet = excel.tables[sheetName];
        if (sheet == null) continue;

        // محاولة اكتشاف الأعمدة من العناوين إن وُجدت
        int? typeCol;
        int? nameCol;
        for (final row in sheet.rows.take(5)) {
          for (var i = 0; i < row.length; i++) {
            final v = (row[i]?.value?.toString() ?? '').trim().toLowerCase();
            if (v.isEmpty) continue;
            if (typeCol == null &&
                (v.contains('نوع') ||
                    v.contains('الصنف') ||
                    v.contains('type'))) {
              typeCol = i;
            }
            if (nameCol == null &&
                (v.contains('اسم') ||
                    v.contains('المادة') ||
                    v.contains('الصنف') ||
                    v.contains('name'))) {
              nameCol = i;
            }
          }
        }
        typeCol ??= 0;
        nameCol ??= 1;

        for (final row in sheet.rows) {
          if (row.isEmpty) continue;

          final rawType = row.length > typeCol
              ? row[typeCol]?.value?.toString().trim()
              : null;
          final rawName = row.length > nameCol
              ? row[nameCol]?.value?.toString().trim()
              : null;
          if (rawType == null ||
              rawType.isEmpty ||
              rawName == null ||
              rawName.isEmpty) {
            skipped++;
            continue;
          }

          // تخطّي صفوف العناوين
          final head = rawName.toLowerCase();
          if (head.contains('اسم') ||
              head.contains('name') ||
              head.contains('الصنف') ||
              head.contains('المادة')) {
            continue;
          }

          // أنشئ النوع إن لم يكن موجودًا
          ItemType type;
          final typeKey = rawType.toLowerCase();
          if (typesMap.containsKey(typeKey)) {
            type = typesMap[typeKey]!;
          } else {
            await repo.addType(rawType);
            type = repo.types.firstWhere(
              (t) => t.name.trim().toLowerCase() == typeKey,
              orElse: () => repo.types.last,
            );
            typesMap[typeKey] = type;
          }

          final key = '${type.id}__${rawName.trim()}';
          if (existingKeys.contains(key)) {
            skipped++;
            continue;
          }

          await repo.addItem(
            typeId: type.id!,
            name: rawName.trim(),
            price: 0,
            initialStock: 0,
          );
          existingKeys.add(key);
          imported++;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'تم استيراد $imported صنف(ًا) بنجاح'
            '${skipped > 0 ? ' (تخطّي $skipped صف/تكرار)' : ''}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر الاستيراد: $e')),
      );
    }
  }

  /// تنزيل نموذج Excel جاهز
  Future<void> _downloadExcelTemplate() async {
    try {
      final excel = xls.Excel.createExcel();
      final sheet = excel['Sheet1'];
      sheet.appendRow(['نوع الصنف', 'اسم الصنف']);
      sheet.appendRow(['حشوات', 'حشوة فضية']);
      sheet.appendRow(['مواد الأشعة', 'فيلم أشعة سينية']);

      final bytes = excel.encode()!;
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/نموذج_إدخال_أصناف.xlsx';
      final file = File(path);
      await file.writeAsBytes(bytes);
      await OpenFile.open(file.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر إنشاء/فتح الملف: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final rawTypes = repo.types;
    final dedup = <String, ItemType>{};
    for (final t in rawTypes) {
      final nameKey = t.name.trim().toLowerCase();
      final key = t.id != null ? 'id:${t.id}' : 'name:$nameKey';
      if (!dedup.containsKey(key)) {
        dedup[key] = t;
      }
    }
    final types = dedup.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    // تأكد أن القيمة المختارة تنتمي لقائمة الأنواع الحالية
    ItemType? resolvedSelected = _selectedType;
    final selected = resolvedSelected;
    if (selected != null) {
      final match = types.cast<ItemType?>().firstWhere(
            (t) =>
                t != null &&
                ((selected.id != null && t.id == selected.id) ||
                    t.name.trim() == selected.name.trim()),
            orElse: () => null,
          );
      resolvedSelected = match;
    }
    if (resolvedSelected != _selectedType && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _selectedType = resolvedSelected);
      });
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('إضافة صنف جديد'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.upload_file, color: Colors.white),
              tooltip: 'استيراد من Excel',
              onPressed: _importItemsFromExcel,
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined, color: Colors.white),
              tooltip: 'تحميل نموذج Excel',
              onPressed: _downloadExcelTemplate,
            ),
          ],
          flexibleSpace: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [lightAccentColor, accentColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          elevation: 4,
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [veryLightBg, Colors.white, veryLightBg],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              // بطاقة معلومات عامة (سطر توضيحي)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: lightAccentColor.withValues(alpha: .35)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .06),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: accentColor),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'أضف صنفًا جديدًا أو استورد مجموعة أصناف من ملف Excel. يمكنك إنشاء نوع جديد أثناء الإدخال.',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // النموذج
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    // نوع الصنف
                    DropdownButtonFormField<ItemType?>(
                      initialValue: _selectedType,
                      decoration: _dec('نوع الصنف',
                          prefixIcon: const Icon(Icons.category_outlined)),
                      items: [
                        ...types.map(
                          (t) => DropdownMenuItem<ItemType?>(
                            value: t,
                            child: Text(t.name),
                          ),
                        ),
                        const DropdownMenuItem<ItemType?>(
                          value: null,
                          child: Text('— إنشاء نوع جديد —'),
                        ),
                      ],
                      onChanged: (val) async {
                        if (val == null) {
                          // فتح نافذة إنشاء نوع جديد
                          await _createNewType();
                        } else {
                          setState(() => _selectedType = val);
                          _nameNode.requestFocus();
                        }
                      },
                      validator: (_) =>
                          _selectedType == null ? 'اختر نوعًا' : null,
                    ),
                    const SizedBox(height: 12),

                    // اسم الصنف
                    TextFormField(
                      controller: _nameCtrl,
                      focusNode: _nameNode,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _stockNode.requestFocus(),
                      decoration: _dec('اسم الصنف',
                          prefixIcon: const Icon(Icons.inventory_2_outlined)),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'أدخل الاسم' : null,
                    ),
                    const SizedBox(height: 12),

                    // الكمية الابتدائية (اختياري)
                    TextFormField(
                      controller: _stockCtrl,
                      focusNode: _stockNode,
                      textInputAction: TextInputAction.done,
                      decoration: _dec('الكمية الابتدائية',
                          prefixIcon: const Icon(Icons.numbers_outlined)),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: false),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        if (n == null || n < 0) return 'أدخل عددًا صحيحًا';
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),

                    // شريط إجراءات سريع (استيراد/نموذج)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _importItemsFromExcel,
                            icon: const Icon(Icons.upload_file),
                            label: const Text('استيراد Excel'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: accentColor,
                              side: const BorderSide(color: lightAccentColor),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _downloadExcelTemplate,
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('نموذج Excel'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: accentColor,
                              side: const BorderSide(color: lightAccentColor),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // زر الحفظ
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isSaving ? null : _submit,
                        icon: _isSaving
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.save_outlined,
                                color: Colors.white),
                        label: const Text('حفظ',
                            style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentColor,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(25)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          elevation: 2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
