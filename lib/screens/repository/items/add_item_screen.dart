// lib/screens/repository/items/add_item_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:excel/excel.dart' as xls;
import 'package:archive/archive.dart';

import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/purchase.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/providers/repository_provider.dart';
import 'package:aelmamclinic/services/repository_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/utils/report_localizer.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

// صفّ خام من ملف Excel.
// نحتفظ بالقيم كنصوص ثم نحولها عند الإدخال لتقليل الأعطال.
class _ImportRow {
  _ImportRow({
    required this.typeName,
    required this.itemName,
    required this.qtyRaw,
  });

  final String typeName;
  final String itemName;
  final String? qtyRaw;
}

class _ImportPreflightResult {
  const _ImportPreflightResult({
    required this.rows,
    required this.total,
    required this.kept,
    required this.duplicates,
    required this.invalidQty,
    required this.skipped,
  });

  final List<_ImportRow> rows;
  final int total;
  final int kept;
  final int duplicates;
  final int invalidQty;
  final int skipped;
}

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

  int? _selectedTypeId;
  bool _isSaving = false;
  bool _isImporting = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _stockCtrl.dispose();
    _nameNode.dispose();
    _stockNode.dispose();
    super.dispose();
  }

  InputDecoration _dec(
    BuildContext context,
    String label, {
    Widget? prefixIcon,
    Widget? suffix,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: context.trRaw(label),
      filled: true,
      fillColor: scheme.surface,
      prefixIcon: prefixIcon,
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _selectedTypeId == null) {
      if (_selectedTypeId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LocalizedText('اختر نوع الصنف')),
        );
      }
      return;
    }
    setState(() => _isSaving = true);
    try {
      final stock = int.parse(_stockCtrl.text);
      final repo = context.read<RepositoryProvider>();
      final type = repo.types.firstWhere(
        (t) => t.id == _selectedTypeId,
        orElse: () => repo.types.isNotEmpty ? repo.types.first : ItemType(name: ''),
      );
      if (type.id == null) {
        throw StateError('نوع الصنف غير صالح');
      }
      await context.read<RepositoryProvider>().addItem(
            typeId: type.id!,
            name: _nameCtrl.text.trim(),
            price: 0,
            initialStock: stock,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LocalizedText('تم حفظ الصنف بنجاح')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('خطأ أثناء الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _tryPauseSync(AuthProvider auth) async {
    final dynamic dyn = auth;
    try {
      await dyn.pauseSync();
    } catch (_) {}
    try {
      await dyn.waitForSyncIdle();
    } catch (_) {}
  }

  Future<void> _tryResumeSync(AuthProvider auth) async {
    final dynamic dyn = auth;
    try {
      await dyn.resumeSync();
    } catch (_) {}
  }

  String _normalizeText(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  _ImportPreflightResult _preflightImport(List<_ImportRow> input) {
    final seen = <String>{};
    final cleaned = <_ImportRow>[];
    var duplicates = 0;
    var invalidQty = 0;
    var skipped = 0;
    for (final row in input) {
      final typeName = _normalizeText(row.typeName);
      final itemName = _normalizeText(row.itemName);
      if (typeName.isEmpty || itemName.isEmpty) {
        skipped++;
        continue;
      }
      final key = '${typeName.toLowerCase()}|${itemName.toLowerCase()}';
      if (seen.contains(key)) {
        duplicates++;
        continue;
      }
      seen.add(key);
      final qtyRaw = (row.qtyRaw ?? '').toString().trim();
      if (qtyRaw.isNotEmpty &&
          int.tryParse(qtyRaw.replaceAll(',', '')) == null) {
        invalidQty++;
      }
      cleaned.add(
        _ImportRow(
          typeName: typeName,
          itemName: itemName,
          qtyRaw: qtyRaw,
        ),
      );
    }
    return _ImportPreflightResult(
      rows: cleaned,
      total: input.length,
      kept: cleaned.length,
      duplicates: duplicates,
      invalidQty: invalidQty,
      skipped: skipped,
    );
  }

  Future<bool> _showPreflightDialog(_ImportPreflightResult result) async {
    if (!mounted) return false;
    final msg = [
      'إجمالي الصفوف: ${result.total}',
      'صفوف صالحة: ${result.kept}',
      'صفوف مكررة: ${result.duplicates}',
      'كميات غير صالحة: ${result.invalidQty}',
      'صفوف فارغة: ${result.skipped}',
      'سيتم اعتبار الكميات غير الصالحة بقيمة 0.',
    ].join('\n');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const LocalizedText('مراجعة قبل الاستيراد'),
        content: LocalizedText(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const LocalizedText('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const LocalizedText('متابعة'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _createNewType() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const LocalizedText('إنشاء نوع صنف جديد'),
        content: TextFormField(
          controller: ctrl,
          decoration: InputDecoration(labelText: context.trRaw('اسم النوع')),
          autofocus: true,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) =>
              Navigator.pop(ctx, ctrl.text.trim().isNotEmpty),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const LocalizedText('إلغاء')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isNotEmpty),
              child: const LocalizedText('إنشاء')),
        ],
      ),
    );
    if (ok == true) {
      if (!mounted) return;
      final name = ctrl.text.trim();
      final repo = context.read<RepositoryProvider>();
      try {
        await repo.addType(name);
      } catch (_) {
        await repo.bootstrap();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LocalizedText('هذا النوع موجود بالفعل')),
        );
      }
      if (!mounted) return;
      // اضبط النوع المختار على النوع الذي أضيف للتو (بأمان)
      final match = repo.types.firstWhere(
        (t) => t.name.trim().toLowerCase() == name.toLowerCase(),
        orElse: () => repo.types.isNotEmpty ? repo.types.last : ItemType(name: name),
      );
      setState(() => _selectedTypeId = match.id);
      // وضع التركيز مباشرة على اسم الصنف
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      _nameNode.requestFocus();
    }
  }

  /// استيراد أصناف من ملف Excel (عمود A: نوع الصنف، عمود B: اسم الصنف، عمود C: الكمية)
  Future<void> _importItemsFromExcel() async {
    if (_isImporting) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xls'],
      withData: true,
    );
    if (result == null) return;
    final picked = result.files.single;
    if (picked.bytes == null && picked.path == null) return;

    if (!mounted) return;
    setState(() => _isImporting = true);
    final auth = context.read<AuthProvider>();
    final progressText = ValueNotifier<String>('جاري قراءة الملف...');
    var dialogClosed = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progressText,
                builder: (_, value, __) => Text(value),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      await _tryPauseSync(auth);
      final bytes = picked.bytes ?? await File(picked.path!).readAsBytes();
      progressText.value = 'جاري تحليل الملف...';
      final excel = _decodeExcelWithRepair(bytes);

      final repo = context.read<RepositoryProvider>();
      if (repo.types.isEmpty) {
        await repo.bootstrap();
      }
      final existingKeys = repo.allItems
          .map((it) => '${it.typeId}__${it.name.trim().toLowerCase()}')
          .toSet();

      int imported = 0;
      int skipped = 0;
      var rawRows = <_ImportRow>[];

      for (final sheetName in excel.tables.keys) {
        final sheet = excel.tables[sheetName];
        if (sheet == null) continue;

        // ترتيب الأعمدة ثابت: A=نوع الصنف, B=اسم الصنف, C=الكمية
        final int typeCol = 0;
        final int nameCol = 1;
        final int qtyCol = 2;

        for (final row in sheet.rows) {
          if (row.isEmpty) continue;

          final rawType = row.length > typeCol
              ? row[typeCol]?.value?.toString().trim()
              : null;
          final rawName = row.length > nameCol
              ? row[nameCol]?.value?.toString().trim()
              : null;
          final rawQty = row.length > qtyCol
              ? row[qtyCol]?.value?.toString().trim()
              : null;
          if (rawType == null ||
              rawType.isEmpty ||
              rawName == null ||
              rawName.isEmpty) {
            skipped++;
            continue;
          }

          // تخطّي صف العناوين إن وُجد
          final head = rawName.toLowerCase();
          if (head.contains('اسم') ||
              head.contains('name') ||
              head.contains('الصنف') ||
              head.contains('المادة')) {
            continue;
          }
          rawRows.add(_ImportRow(
            typeName: rawType,
            itemName: rawName,
            qtyRaw: rawQty,
          ));
        }
      }

      if (rawRows.isEmpty) {
        throw StateError('لا توجد بيانات صالحة في الملف');
      }

      final preflight = _preflightImport(rawRows);
      rawRows = preflight.rows;
      skipped += preflight.skipped + preflight.duplicates;
      if (rawRows.isEmpty) {
        throw StateError('لا توجد بيانات صالحة بعد التحقق');
      }
      final confirmed = await _showPreflightDialog(preflight);
      if (!confirmed) {
        throw StateError('تم إلغاء الاستيراد');
      }

      progressText.value = 'جاري تجهيز الأنواع...';
      final typesMap = <String, ItemType>{
        for (final t in repo.types) t.name.trim().toLowerCase(): t
      };
      final neededTypes = <String>{};
      for (final row in rawRows) {
        neededTypes.add(row.typeName.trim().toLowerCase());
      }
      for (final typeKey in neededTypes) {
        if (typesMap.containsKey(typeKey)) continue;
        final originalName = rawRows
            .firstWhere((r) => r.typeName.trim().toLowerCase() == typeKey)
            .typeName
            .trim();
        try {
          await repo.addType(originalName);
        } catch (_) {
          await repo.bootstrap();
        }
      }
      // إعادة تحميل الأنواع بعد الإضافة لضمان تزامن الـ Provider مع قاعدة البيانات.
      await repo.bootstrap();
      typesMap
        ..clear()
        ..addAll({
          for (final t in repo.types) t.name.trim().toLowerCase(): t,
        });
      final typeNameById = <int, String>{
        for (final t in repo.types)
          if (t.id != null) t.id!: t.name,
      };
      // أعِد بناء خريطة الاسم -> المعرف من قاعدة البيانات لتفادي أي حالة
      // عدم تزامن بين Provider والحفظ الفعلي.
      final typeIdByName = <String, int>{};
      final db = RepositoryService.instance.db;
      final database = await db.database;
      for (final typeKey in neededTypes) {
        final args = <Object?>[typeKey];
        final acc = await db.accountFilterClause(
          database,
          ItemType.table,
          args: args,
        );
        final rows = await database.rawQuery(
          '''
          SELECT id, name FROM ${ItemType.table}
           WHERE lower(name) = lower(?)
           $acc
           ORDER BY id DESC
           LIMIT 1
          ''',
          args,
        );
        if (rows.isNotEmpty) {
          typeIdByName[typeKey] = (rows.first['id'] as num).toInt();
        }
      }

      progressText.value = 'جاري إدخال الأصناف...';
      final itemsToInsert = <Item>[];
      final itemsToReassign = <Map<String, dynamic>>[];
      final qtyByKey = <String, int>{};
      for (final row in rawRows) {
        final typeKey = row.typeName.trim().toLowerCase();
        final typeId = typeIdByName[typeKey] ?? typesMap[typeKey]?.id;
        if (typeId == null) {
          skipped++;
          continue;
        }
        final name = row.itemName.trim();
        final key = '${typeId}__${name.toLowerCase()}';
        if (existingKeys.contains(key)) {
          skipped++;
          continue;
        }
        // إن وُجد نفس الاسم بنوع مختلف سابقًا، صحّح type_id بدل إنشاء صنف جديد.
        final lookupArgs = <Object?>[name];
        final lookupAcc = await db.accountFilterClause(
          database,
          Item.table,
          args: lookupArgs,
        );
        final existingRows = await database.rawQuery(
          '''
          SELECT id, type_id FROM ${Item.table}
           WHERE lower(name) = lower(?)
           $lookupAcc
           ORDER BY id DESC
           LIMIT 1
          ''',
          lookupArgs,
        );
        if (existingRows.isNotEmpty) {
          final existingId = (existingRows.first['id'] as num).toInt();
          final existingTypeId = (existingRows.first['type_id'] as num?)?.toInt();
          if (existingTypeId == null || existingTypeId != typeId) {
            itemsToReassign.add({
              'id': existingId,
              'type_id': typeId,
            });
          }
          existingKeys.add(key);
          continue;
        }
        final qty = int.tryParse((row.qtyRaw ?? '').replaceAll(',', '')) ?? 0;
        itemsToInsert.add(Item(
          typeId: typeId,
          name: name,
          price: 0,
          stock: 0,
        ));
        qtyByKey[key] = qty < 0 ? 0 : qty;
        existingKeys.add(key);
      }

      if (itemsToInsert.isNotEmpty) {
        final DBService db = RepositoryService.instance.db;
        await db.runQueuedWrite(() async {
          await db.runWithDbRetry(() async {
            final database = await db.database;
            const chunkSize = 300;
            final total = itemsToInsert.length;
            var reassignApplied = false;
            for (var i = 0; i < total; i += chunkSize) {
              final end = (i + chunkSize > total) ? total : i + chunkSize;
              progressText.value = 'جاري إدخال الأصناف... ($end / $total)';
              await database.transaction((txn) async {
                final batch = txn.batch();
                // صحّح النوع للأصناف القديمة (مثلاً كانت تحت "غير مصنف")
                if (!reassignApplied && itemsToReassign.isNotEmpty) {
                  final now = DateTime.now().toIso8601String();
                  for (final fix in itemsToReassign) {
                    batch.update(
                      Item.table,
                      {
                        'type_id': fix['type_id'],
                        'updated_at': now,
                      },
                      where: 'id = ?',
                      whereArgs: [fix['id']],
                    );
                  }
                  reassignApplied = true;
                }
                for (var j = i; j < end; j++) {
                  final item = itemsToInsert[j];
                  final data = await db.prepareInsert(
                    Item.table,
                    item.toMap(),
                    executor: txn,
                  );
                  batch.insert(Item.table, data);
                }
                await batch.commit(noResult: true);

                for (var j = i; j < end; j++) {
                  final item = itemsToInsert[j];
                  final key = '${item.typeId}__${item.name.toLowerCase()}';
                  final qty = qtyByKey[key] ?? 0;
                  if (qty <= 0) continue;

                  final lookupArgs = <Object?>[item.typeId, item.name.trim()];
                  final acc = await db.accountFilterClause(
                    txn,
                    Item.table,
                    args: lookupArgs,
                  );
                  final rows = await txn.rawQuery(
                    '''
                    SELECT id FROM ${Item.table}
                     WHERE type_id = ?
                       AND lower(name) = lower(?)
                       $acc
                     ORDER BY id DESC
                     LIMIT 1
                    ''',
                    lookupArgs,
                  );
                  if (rows.isEmpty) continue;
                  final itemId = (rows.first['id'] as num).toInt();

                  final purchase = Purchase(
                    itemId: itemId,
                    quantity: qty,
                    unitPrice: 0,
                  );
                  final pData = await db.prepareInsert(
                    Purchase.table,
                    purchase.toMap()
                      ..addAll({
                        if (typeNameById[item.typeId] != null)
                          'item_type_name_snapshot': typeNameById[item.typeId],
                        'item_name_snapshot': item.name,
                      }),
                    executor: txn,
                  );
                  await txn.insert(Purchase.table, pData);
                  final hasUpdatedAt =
                      await db.hasColumn(txn, Item.table, 'updated_at');
                  final stockArgs = <Object?>[qty, itemId];
                  final accClause = await db.accountFilterClause(
                    txn,
                    Item.table,
                    args: stockArgs,
                  );
                  final sql = hasUpdatedAt
                      ? 'UPDATE ${Item.table} SET stock = stock + ?, updated_at = ? WHERE id = ? $accClause'
                      : 'UPDATE ${Item.table} SET stock = stock + ? WHERE id = ? $accClause';
                  if (hasUpdatedAt) {
                    stockArgs.insert(1, DateTime.now().toIso8601String());
                  }
                  await txn.rawUpdate(sql, stockArgs);
                }
              });
              // إتاحة تحديث واجهة المستخدم بين الدُفعات
              await Future<void>.delayed(Duration.zero);
            }
          });
        });
        await db.notifyTableChanged(Item.table);
        await db.notifyTableChanged(Purchase.table);
        imported = itemsToInsert.length;
        if (mounted && !dialogClosed) {
          dialogClosed = true;
          Navigator.of(context, rootNavigator: true).pop();
        }
        // تحديث البيانات في الخلفية بدون حبس واجهة المستخدم
        Future(() async {
          try {
            await DBService.instance.repairInventoryIntegrity(backup: true);
            await repo.bootstrap();
          } catch (_) {}
        });
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: LocalizedText('تم استيراد $imported صنف(ًا) بنجاح'
            '${skipped > 0 ? ' (تخطّي $skipped صف/تكرار)' : ''}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذّر الاستيراد: $e')),
      );
    } finally {
      await _tryResumeSync(auth);
      if (mounted) {
        if (!dialogClosed) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        setState(() => _isImporting = false);
      }
    }
  }

  /// تنزيل نموذج Excel جاهز
  Future<void> _downloadExcelTemplate() async {
    try {
      final excel = xls.Excel.createExcel();
      final sheet = excel['Sheet1'];
      sheet.appendRow(['نوع الصنف', 'اسم الصنف', 'الكمية']);
      sheet.appendRow(['حشوات', 'حشوة فضية', 10]);
      sheet.appendRow(['مواد الأشعة', 'فيلم أشعة سينية', 5]);

      final bytes = excel.encode()!;
      final dir = await getTemporaryDirectory();
      final i18n = ReportLocalizer();
      final path =
          '${dir.path}/${i18n.fileName('نموذج إدخال أصناف', extension: 'xlsx')}';
      final file = File(path);
      await file.writeAsBytes(bytes);
      await OpenFile.open(file.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('تعذّر إنشاء/فتح الملف: $e')),
      );
    }
  }

  xls.Excel _decodeExcelWithRepair(List<int> bytes) {
    try {
      return xls.Excel.decodeBytes(bytes);
    } catch (_) {
      final repaired = _repairExcelBytes(bytes);
      return xls.Excel.decodeBytes(repaired);
    }
  }

  List<int> _repairExcelBytes(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    const stylesPath = 'xl/styles.xml';
    const minimalStyles = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="1"><font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/><scheme val="minor"/></font></fonts>
  <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
''';

    bool replaced = false;
    for (var i = 0; i < archive.length; i++) {
      final f = archive[i];
      if (f.isFile && f.name == stylesPath) {
        archive[i] =
            ArchiveFile(stylesPath, minimalStyles.length, minimalStyles.codeUnits);
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      archive.addFile(
        ArchiveFile(stylesPath, minimalStyles.length, minimalStyles.codeUnits),
      );
    }
    final out = ZipEncoder().encode(archive);
    return out ?? bytes;
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<RepositoryProvider>();
    final scheme = Theme.of(context).colorScheme;
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
    int? resolvedSelectedId = _selectedTypeId;
    if (resolvedSelectedId != null &&
        !types.any((t) => t.id == resolvedSelectedId)) {
      resolvedSelectedId = null;
    }
    if (resolvedSelectedId != _selectedTypeId && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _selectedTypeId = resolvedSelectedId);
      });
    }

    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        appBar: AppBar(
          title: const LocalizedText('إضافة صنف جديد'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.upload_file),
              tooltip: context.trRaw('استيراد من Excel'),
              onPressed: _isImporting ? null : _importItemsFromExcel,
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: context.trRaw('تحميل نموذج Excel'),
              onPressed: _downloadExcelTemplate,
            ),
          ],
          flexibleSpace: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primaryContainer,
                  Theme.of(context).colorScheme.primary
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.surfaceContainerHigh,
                Theme.of(context).colorScheme.surface,
                Theme.of(context).colorScheme.surfaceContainerHigh,
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: ListView(
            padding: kScreenPadding.copyWith(top: 14, bottom: 24),
            children: [
              // بطاقة معلومات عامة (سطر توضيحي)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: .5),
                  ),
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
                    Icon(Icons.info_outline, color: kPrimaryColor),
                    SizedBox(width: 8),
                    Expanded(
                      child: LocalizedText('أضف صنفًا جديدًا أو استورد مجموعة أصناف من ملف Excel. يمكنك إنشاء نوع جديد أثناء الإدخال.',
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
                    DropdownButtonFormField<int?>(
                      initialValue: _selectedTypeId,
                      decoration: _dec(context, 'نوع الصنف',
                          prefixIcon: const Icon(Icons.category_outlined)),
                      items: [
                        ...types.map(
                          (t) => DropdownMenuItem<int?>(
                            value: t.id,
                            child: Text(t.name),
                          ),
                        ),
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: LocalizedText('— إنشاء نوع جديد —'),
                        ),
                      ],
                      onChanged: (val) async {
                        if (val == null) {
                          // فتح نافذة إنشاء نوع جديد
                          await _createNewType();
                        } else {
                          setState(() => _selectedTypeId = val);
                          _nameNode.requestFocus();
                        }
                      },
                      validator: (_) =>
                          _selectedTypeId == null ? 'اختر نوعًا' : null,
                    ),
                    const SizedBox(height: 12),

                    // اسم الصنف
                    TextFormField(
                      controller: _nameCtrl,
                      focusNode: _nameNode,
                      textInputAction: TextInputAction.next,
                      onFieldSubmitted: (_) => _stockNode.requestFocus(),
                      decoration: _dec(context, 'اسم الصنف',
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
                      decoration: _dec(context, 'الكمية الابتدائية',
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
                            onPressed: _isImporting ? null : _importItemsFromExcel,
                            icon: const Icon(Icons.upload_file),
                            label: const LocalizedText('استيراد Excel'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: scheme.primary,
                              side: BorderSide(
                                  color: scheme.primary.withValues(alpha: .35)),
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
                            label: const LocalizedText('نموذج Excel'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: scheme.primary,
                              side: BorderSide(
                                  color: scheme.primary.withValues(alpha: .35)),
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
                        label: const LocalizedText('حفظ',
                            style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: scheme.primary,
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
