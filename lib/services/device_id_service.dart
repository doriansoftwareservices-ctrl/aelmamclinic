// lib/services/device_id_service.dart
//
// خدمة معرّف الجهاز الثابت للمزامنة بين الأجهزة.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:shared_preferences/shared_preferences.dart';

class DeviceIdService {
  // (اختياري) Singleton لاستخدامات مستقبلية
  DeviceIdService._();
  static final DeviceIdService instance = DeviceIdService._();

  static const String _prefsKey = 'auth.deviceId';
  static const String _fileName = 'device_id.txt';

  // نمط UUID v4 للتحقق القوي
  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  static String? _cache;
  static Future<String>? _inflight;

  /// احصل على معرّف الجهاز الثابت (ينشئه عند الحاجة).
  static Future<String> getId() async {
    if (_inflight != null) return _inflight!;
    if (_isValid(_cache)) return _cache!;

    _inflight = _resolveId().whenComplete(() => _inflight = null);
    _cache = await _inflight!;
    return _cache!;
  }

  /// قراءة سريعة من الذاكرة فقط (إن وُجدت) بدون أي I/O.
  static String? getIdCached() => _cache;

  /*──────────────────────── داخلي ────────────────────────*/

  static Future<String> _resolveId() async {
    // 1) SharedPreferences
    try {
      final sp = await SharedPreferences.getInstance();
      final fromPrefs = sp.getString(_prefsKey);
      if (_isValid(fromPrefs)) {
        // اكتب نسخة احتياطية على القرص إن لم تكن موجودة
        unawaited(_writeToFileIfMissing(fromPrefs!));
        return fromPrefs!;
      }

      // 2) من ملف احتياطي
      final fromFile = await _readFromFile();
      if (_isValid(fromFile)) {
        await sp.setString(_prefsKey, fromFile!);
        return fromFile!;
      }

      // 3) توليد UUID v4
      final generated = _uuidV4();
      await sp.setString(_prefsKey, generated);
      unawaited(_writeToFile(generated));
      return generated;
    } catch (_) {
      // في حال فشل SharedPreferences لأي سبب، نحاول المسار الاحتياطي ثم نولّد
      final fromFile = await _readFromFile();
      if (_isValid(fromFile)) return fromFile!;
      final generated = _uuidV4();
      unawaited(_writeToFile(generated));
      return generated;
    }
  }

  static bool _isValid(String? v) {
    if (v == null) return false;
    final s = v.trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return false;
    // نقبل أي قيمة غير فارغة، لكن نفضّل UUIDv4 الصحيح.
    // لو كانت غير مطابقة للنمط، نسمح بها طالما ليست 'null' أو فارغة
    // حفاظًا على أي معرفات قديمة؛ إن أردت إجبار UUIDv4 فقط فعّل السطر التالي:
    // return _uuidV4Pattern.hasMatch(s);
    return true;
  }

  static Future<String> _deviceIdFilePath() async {
    if (Platform.isWindows) {
      // 0) مسار مخصّص عبر متغيّر بيئي AELMAM_DIR (إن وُجد)
      try {
        final env = Platform
            .environment; // قد يرمي فقط على منصّات غير مدعومة، وهنا نحن على ويندوز.
        final customRoot = env['AELMAM_DIR'] ?? env['AELMAM_CLINIC_DIR'];
        if (customRoot != null && customRoot.trim().isNotEmpty) {
          final d = Directory(customRoot.trim());
          if (!await d.exists()) {
            await d.create(recursive: true);
          }
          return p.join(d.path, _fileName);
        }
      } catch (_) {
        // تجاهل ونكمل بالمرشّحات التالية
      }

      // 1) المجلد المفضّل الثابت على D:\ للحفاظ على الهوية عبر إعادة التثبيت
      const preferred = r'D:\aelmam_clinic';
      try {
        final d = Directory(preferred);
        if (!await d.exists()) {
          await d.create(recursive: true);
        }
        return p.join(preferred, _fileName);
      } catch (_) {
        // فشل الإنشاء/الوصول → ننتقل للـ fallback
      }

      // 2) Fallback: Application Support
      final sup = await path_provider.getApplicationSupportDirectory();
      await sup.create(recursive: true);
      return p.join(sup.path, _fileName);
    } else {
      // باقي الأنظمة: Application Support
      final sup = await path_provider.getApplicationSupportDirectory();
      await sup.create(recursive: true);
      return p.join(sup.path, _fileName);
    }
  }

  static Future<String?> _readFromFile() async {
    try {
      final path = await _deviceIdFilePath();
      final f = File(path);
      if (await f.exists()) {
        // قد يحتوي الملف على أسطر إضافية؛ نأخذ أول سطر صالح فقط
        final txt = await f.readAsString();
        final id = txt.split('\n').first.trim();
        return _isValid(id) ? id : null;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _writeToFile(String id) async {
    try {
      final path = await _deviceIdFilePath();
      final f = File(path);
      await f.create(recursive: true);
      await f.writeAsString('${id.trim()}\n', mode: FileMode.write);
    } catch (_) {
      // صامت: عدم القدرة على حفظ النسخة الاحتياطية لا يُعدّ خطأ قاتلاً
    }
  }

  static Future<void> _writeToFileIfMissing(String id) async {
    try {
      final path = await _deviceIdFilePath();
      final f = File(path);
      if (!await f.exists()) {
        await _writeToFile(id);
      } else {
        // حتى لو موجود، لو كان المحتوى غير صالح سنستبدله
        final current = await _readFromFile();
        if (!_isValid(current)) {
          await _writeToFile(id);
        }
      }
    } catch (_) {}
  }

  static String _uuidV4() {
    final rnd = Random.secure();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant RFC4122
    String h(int x) => x.toRadixString(16).padLeft(2, '0');
    return '${h(b[0])}${h(b[1])}${h(b[2])}${h(b[3])}-'
        '${h(b[4])}${h(b[5])}-'
        '${h(b[6])}${h(b[7])}-'
        '${h(b[8])}${h(b[9])}-'
        '${h(b[10])}${h(b[11])}${h(b[12])}${h(b[13])}${h(b[14])}${h(b[15])}';
  }

  /// Debug فقط — يفرض هوية جديدة (Prefs + ملف) ويحدّث الكاش.
  static Future<void> overrideForDebug(String newId) async {
    final id = newId.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefsKey, id);
    unawaited(_writeToFile(id));
    _cache = id;
  }

  /// Debug: إعادة تعيين الهوية محليًا (Prefs + ملف) لبدء سلوك مزامنة جديد.
  static Future<void> resetForDebug() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_prefsKey);
    } catch (_) {}
    try {
      final path = await _deviceIdFilePath();
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
    _cache = null;
  }
}
