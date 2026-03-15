// lib/utils/excel_export_helper.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;

import 'package:aelmamclinic/models/item_type.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/models/purchase.dart';
import 'package:aelmamclinic/services/save_file_service.dart';
import 'package:aelmamclinic/services/repository_service.dart';
import 'package:aelmamclinic/utils/report_localizer.dart';

/// ‎ExcelExportHelper‎:
/// • يُولّد ملفات ‎.xlsx‎ بتنسيقٍ يُناسب "إحصاءات وكشوفات المستودع".
/// • يحفظ الملفات في مجلّد "Downloads" إن وُجد.
///
class ExcelExportHelper {
  ExcelExportHelper._();

  /// ⬇️ exportItemStatistics
  static Future<String> exportItemStatistics({
    required ItemType type,
    required List<Item> items,
    String? exportsDir,
  }) async {
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'إحصاءات' : 'Statistics'];

    // رأس الجدول
    sheet.appendRow([
      i18n.tr('نوع الصنف'),
      i18n.tr('اسم الصنف'),
      i18n.tr('عدد المستخدم'),
      i18n.tr('المتبقي في المخزون'),
      i18n.tr('السعر للوحدة'),
    ]);

    // تحميل إجمالي الاستهلاك لكل صنف (للدقة)
    final usageByItemId = <int, int>{};
    try {
      final ids = items.map((e) => e.id).whereType<int>().toList();
      if (ids.isNotEmpty) {
        final db = await RepositoryService.instance.database;
        final placeholders = List.filled(ids.length, '?').join(',');
        final rows = await db.rawQuery('''
          SELECT CAST(itemId AS INTEGER) AS item_id,
                 COALESCE(SUM(quantity),0) AS used
            FROM consumptions
           WHERE ifnull(isDeleted,0)=0
             AND itemId IN ($placeholders)
        GROUP BY CAST(itemId AS INTEGER)
        ''', ids);
        for (final row in rows) {
          final id = (row['item_id'] as num?)?.toInt();
          if (id == null) continue;
          usageByItemId[id] = (row['used'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (_) {
      // في حال فشل الاستعلام، نتابع بدون استخدامات
    }

    // تعبئة البيانات
    for (final item in items) {
      final used = usageByItemId[item.id ?? -1] ?? 0;
      final remaining = item.stock < 0 ? 0 : item.stock;
      sheet.appendRow([
        type.name,
        item.name,
        used,
        remaining,
        item.price,
      ]);
    }

    // حفظ في Downloads
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = i18n.fileName(
      'إحصائيات الأصناف',
      extension: 'xlsx',
      suffixes: <Object?>[type.name, type.id ?? timestamp, timestamp],
    );

    final bytes = excel.encode();
    if (bytes == null) throw Exception(i18n.tr('فشل في إنشاء ملف Excel.'));
    if (exportsDir != null && exportsDir.trim().isNotEmpty) {
      final path = p.join(exportsDir, fileName);
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    }
    final path =
        await saveFileBytesWithPath(Uint8List.fromList(bytes), fileName);
    return path;
  }

  /// ⬇️ exportItemConsumptions
  static Future<String> exportItemConsumptions({
    required Item item,
    required List<Consumption> consumptions,
    String? exportsDir,
  }) async {
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'استهلاكات' : 'Consumptions'];

    sheet.appendRow([
      i18n.tr('اسم الصنف'),
      i18n.tr('تاريخ ووقت الاستهلاك'),
      i18n.tr('المريض (patientId)'),
      i18n.tr('الكمية المستهلكة'),
    ]);

    consumptions.sort((a, b) => a.consumedAt.compareTo(b.consumedAt));
    for (final c in consumptions) {
      sheet.appendRow([
        item.name,
        c.consumedAt.toString(),
        c.patientId,
        c.quantity,
      ]);
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = i18n.fileName(
      'استهلاكات الصنف',
      extension: 'xlsx',
      suffixes: <Object?>[item.name, item.id ?? timestamp, timestamp],
    );

    final bytes = excel.encode();
    if (bytes == null) throw Exception(i18n.tr('فشل في إنشاء ملف Excel.'));
    if (exportsDir != null && exportsDir.trim().isNotEmpty) {
      final path = p.join(exportsDir, fileName);
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    }
    final path =
        await saveFileBytesWithPath(Uint8List.fromList(bytes), fileName);
    return path;
  }

  /// ⬇️ exportPurchases
  static Future<String> exportPurchases({
    required List<Purchase> purchases,
    required Map<int, Item> lookupItems,
    String? exportsDir,
  }) async {
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'مشتريات' : 'Purchases'];

    sheet.appendRow([
      i18n.tr('اسم الصنف'),
      i18n.tr('الكمية'),
      i18n.tr('سعر الوحدة'),
      i18n.tr('الإجمالي'),
      i18n.tr('التاريخ/الوقت'),
    ]);

    purchases.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final pch in purchases) {
      final item = lookupItems[pch.itemId];
      sheet.appendRow([
        item?.name ?? 'ID ${pch.itemId}',
        pch.quantity,
        pch.unitPrice,
        pch.totalPrice,
        pch.createdAt.toString(),
      ]);
    }

    final fileName = i18n.fileName(
      'المشتريات',
      extension: 'xlsx',
      suffixes: <Object?>[DateTime.now().millisecondsSinceEpoch],
    );

    final bytes = excel.encode();
    if (bytes == null) throw Exception(i18n.tr('فشل في إنشاء ملف Excel.'));
    if (exportsDir != null && exportsDir.trim().isNotEmpty) {
      final path = p.join(exportsDir, fileName);
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    }
    final path =
        await saveFileBytesWithPath(Uint8List.fromList(bytes), fileName);
    return path;
  }
}
