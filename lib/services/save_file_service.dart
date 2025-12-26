// lib/services/save_file_service.dart
//
// حفظ ملف (مثل Excel) عبر منصّات متعددة مع اختيار مجلد مناسب واسم ملف آمن:
// - Windows/macOS/Linux: يحاول مجلد "Downloads" ثم يسقط إلى Documents.
// - Android: يحاول مجلد التنزيلات العام (إن كان متاحًا) ثم يسقط إلى
//   مجلد التطبيق الخارجي ثم Documents.
// - iOS: يحفظ داخل Documents (لا يوجد "Downloads" عام).
// - يتجنب الاستبدال بإضافة لاحقة (1), (2)...
// - يعقّم اسم الملف ويعرض Toast بالنتيجة.
//
// المتطلبات في pubspec.yaml:
//   path_provider: ^2.1.0
//   path: ^1.8.0
//   fluttertoast: ^8.2.0
//
// ملاحظات Android:
// - الكتابة في مجلد التنزيلات العام قد تُقيَّد بسبب Scoped Storage.
//   في هذه الحالة سنسقط تلقائيًا إلى مسار آمن داخل التطبيق.

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show kIsWeb; // احتياط (لو تم الاستيراد للويب)
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:fluttertoast/fluttertoast.dart';

/// يحفظ بايتات ملف باسم [fileName] ويُظهر Toast بالمسار النهائي.
Future<void> saveFileBytes(Uint8List bytes, String fileName) async {
  await saveFileBytesWithPath(bytes, fileName);
}

/// يحفظ بايتات ملف باسم [fileName] ويُعيد المسار النهائي.
Future<String> saveFileBytesWithPath(Uint8List bytes, String fileName) async {
  if (kIsWeb) {
    Fluttertoast.showToast(
      msg: "الحفظ المباشر غير مدعوم على الويب في هذا المسار.",
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
    );
    return '';
  }

  try {
    final dir = await _resolveTargetDirectory();
    await dir.create(recursive: true);

    final safeName = _sanitizeFileName(fileName);
    final targetPath = await _uniqueFilePath(dir.path, safeName);

    final file = File(targetPath);
    await file.writeAsBytes(bytes, flush: true);

    Fluttertoast.showToast(
      msg: "تم حفظ الملف بنجاح في: ${file.path}",
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
    );
    return file.path;
  } catch (e) {
    Fluttertoast.showToast(
      msg: "فشل حفظ الملف: $e",
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
    );
    return '';
  }
}

/// يحفظ بايتات ملف (Excel مثلًا) باسم [fileName] ويُظهر Toast بالمسار النهائي.
Future<void> saveExcelFile(Uint8List bytes, String fileName) async {
  await saveFileBytes(bytes, fileName);
}

/// ينسخ ملفًا موجودًا إلى مجلد مناسب حسب المنصة ويُعيد المسار النهائي.
Future<String> saveFileToDownloads(File file, {String? fileName}) async {
  if (kIsWeb) {
    Fluttertoast.showToast(
      msg: "الحفظ المباشر غير مدعوم على الويب في هذا المسار.",
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
    );
    return '';
  }

  try {
    final dir = await _resolveTargetDirectory();
    await dir.create(recursive: true);

    final safeName = _sanitizeFileName(fileName ?? p.basename(file.path));
    final targetPath = await _uniqueFilePath(dir.path, safeName);
    final copied = await file.copy(targetPath);

    Fluttertoast.showToast(
      msg: "تم حفظ الملف بنجاح في: ${copied.path}",
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
    );
    return copied.path;
  } catch (e) {
    Fluttertoast.showToast(
      msg: "فشل حفظ الملف: $e",
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.BOTTOM,
    );
    return '';
  }
}

/// يحدّد مجلد الهدف حسب المنصة مع فواصل آمنة.
Future<Directory> _resolveTargetDirectory() async {
  // سطح المكتب
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    // 1) جرّب Downloads الرسمي من path_provider
    try {
      final dl = await getDownloadsDirectory();
      if (dl != null) return dl;
    } catch (_) {}
    // 2) بناء مسار Downloads يدويًا
    try {
      final home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        final manual = Directory(p.join(home, 'Downloads'));
        if (manual.existsSync()) return manual;
      }
    } catch (_) {}
    // 3) سقوط إلى Documents
    return await getApplicationDocumentsDirectory();
  }

  // iOS
  if (Platform.isIOS) {
    return await getApplicationDocumentsDirectory();
  }

  // Android
  if (Platform.isAndroid) {
    // 1) جرّب مجلد التنزيلات العام (قد يفشل بسبب الصلاحيات/Scoped Storage)
    try {
      final list =
          await getExternalStorageDirectories(type: StorageDirectory.downloads);
      if (list != null && list.isNotEmpty) {
        return list.first;
      }
    } catch (_) {}
    // 2) جرّب مجلد خارجي خاص بالتطبيق
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    } catch (_) {}
    // 3) سقوط إلى Documents
    return await getApplicationDocumentsDirectory();
  }

  // منصات أخرى: Documents
  return await getApplicationDocumentsDirectory();
}

/// يعقّم اسم الملف لإزالة المحارف غير المقبولة على الأنظمة المختلفة.
String _sanitizeFileName(String input) {
  var name = input.trim();
  if (name.isEmpty) {
    name = 'file_${DateTime.now().millisecondsSinceEpoch}.xlsx';
  }
  // إزالة المسارات في حال أُرسل اسم يتضمن دلائل
  name = p.basename(name);
  // استبدال محارف غير مدعومة
  name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  // منع الأسماء المحجوزة على ويندوز مثل CON و PRN...
  const reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  final base = p.basenameWithoutExtension(name).toUpperCase();
  final ext = p.extension(name);
  if (reserved.contains(base)) {
    name = '${base}_$ext';
  }
  // تجنّب أسماء تنتهي بنقطة أو مسافة على ويندوز
  name = name.replaceAll(RegExp(r'[\. ]+$'), '');
  if (name.isEmpty) {
    name = 'file_${DateTime.now().millisecondsSinceEpoch}.xlsx';
  }
  return name;
}

/// يولّد مسارًا فريدًا إن كان هناك ملف بنفس الاسم: name.xlsx → name (1).xlsx ...
Future<String> _uniqueFilePath(String dirPath, String fileName) async {
  String candidate = p.join(dirPath, fileName);
  if (!await File(candidate).exists()) return candidate;

  final name = p.basenameWithoutExtension(fileName);
  final ext = p.extension(fileName).replaceFirst('.', '');
  var i = 1;
  while (true) {
    final alt = p.join(dirPath, '$name ($i)${ext.isNotEmpty ? '.$ext' : ''}');
    if (!await File(alt).exists()) return alt;
    i++;
  }
}
