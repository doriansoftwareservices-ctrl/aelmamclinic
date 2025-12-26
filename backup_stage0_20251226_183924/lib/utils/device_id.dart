// lib/utils/device_id.dart
//
// توليد معرف جهاز ثابت (persistent) متعدد المنصات.
// - يولّد UUID v4 مرة واحدة ويخزّنه في SharedPreferences.
// - آمن للتوازي عبر _inflight لحماية من سباقات الكتابة.
// - يدعم ترحيل مفاتيح قديمة تلقائيًا إن وُجدت.
// - يوفّر أدوات مساعدة اختيارية (cached/clear/bytes).

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

class DeviceId {
  DeviceId._();

  static const String _prefsKey = 'device_id';
  static const List<String> _legacyKeys = <String>[
    'deviceId',
    'deviceID',
    'app_device_id'
  ];

  static String? _cached;
  static Future<String>? _inflight;

  static Future<String> get() async {
    if (_cached != null && _cached!.isNotEmpty) return _cached!;
    if (_inflight != null) return _inflight!;
    _inflight = _loadOrCreate();
    try {
      final id = await _inflight!;
      _cached = id;
      return id;
    } finally {
      _inflight = null;
    }
  }

  static Future<bool> exists() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_prefsKey);
    if (v != null && v.isNotEmpty) return true;
    for (final k in _legacyKeys) {
      final lv = prefs.getString(k);
      if (lv != null && lv.isNotEmpty) return true;
    }
    return false;
  }

  static Future<String> short() async {
    final id = await get();
    final compact = id.replaceAll('-', '');
    return compact.length >= 8 ? compact.substring(0, 8) : compact;
  }

  static Future<String> regenerate() async {
    final prefs = await SharedPreferences.getInstance();
    final fresh = _generateUuidV4();
    await prefs.setString(_prefsKey, fresh);
    _cached = fresh;
    return fresh;
  }

  static String? getCachedOrNull() => _cached;

  static String? shortCachedOrNull() {
    final id = _cached;
    if (id == null || id.isEmpty) return null;
    final compact = id.replaceAll('-', '');
    return compact.length >= 8 ? compact.substring(0, 8) : compact;
  }

  static Future<bool> clearForDebug() async {
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.remove(_prefsKey);
    _cached = null;
    return ok;
  }

  static bool isValidUuidV4(String v) => _looksLikeUuidV4(v);

  static Uint8List uuidToBytes(String uuid) {
    final hex = uuid.replaceAll('-', '');
    if (hex.length != 32) throw const FormatException('Invalid UUID length');
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String bytesToUuid(Uint8List bytes) {
    if (bytes.length != 16) {
      throw const FormatException('UUID bytes must be length 16');
    }
    final hex = _toHex(bytes);
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  // ─────────────────── داخلي ───────────────────

  static Future<String> _loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();

    // 1) المفتاح الرسمي
    var existing = prefs.getString(_prefsKey);

    // 2) جرب الترحيل من مفاتيح قديمة
    if (existing == null || existing.isEmpty || !_looksLikeUuidV4(existing)) {
      for (final k in _legacyKeys) {
        final legacy = prefs.getString(k);
        if (legacy != null && legacy.isNotEmpty && _looksLikeUuidV4(legacy)) {
          existing = legacy;
          await prefs.setString(_prefsKey, existing);
          break;
        }
      }
    }

    // 3) أنشئ جديدًا لو لزم
    if (existing == null || existing.isEmpty || !_looksLikeUuidV4(existing)) {
      existing = _generateUuidV4();
      await prefs.setString(_prefsKey, existing);
    }
    return existing;
  }

  static bool _looksLikeUuidV4(String v) {
    final re = RegExp(
      r'^[0-9a-fA-F]{8}-'
      r'[0-9a-fA-F]{4}-'
      r'4[0-9a-fA-F]{3}-'
      r'[89abAB][0-9a-fA-F]{3}-'
      r'[0-9a-fA-F]{12}$',
    );
    return re.hasMatch(v);
  }

  static String _generateUuidV4() {
    final rand = _safeRandom();
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = rand.nextInt(256);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant

    final hex = _toHex(bytes);
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  static Random _safeRandom() {
    try {
      return Random.secure();
    } catch (_) {
      final seed = DateTime.now().microsecondsSinceEpoch ^
          base64Url.encode(utf8.encode(_stackHint())).hashCode ^
          Random().nextInt(1 << 31);
      return Random(seed);
    }
  }

  static String _toHex(Uint8List bytes) {
    const chars = '0123456789abcdef';
    final sb = StringBuffer();
    for (final b in bytes) {
      sb
        ..write(chars[b >> 4])
        ..write(chars[b & 0x0f]);
    }
    return sb.toString();
  }

  static String _stackHint() {
    try {
      throw StateError('seed');
    } catch (e, s) {
      return s.toString();
    }
  }
}

/// طبقة توافق: بعض الخدمات تستدعي DeviceIdService.getId()
class DeviceIdService {
  static Future<String> getId() => DeviceId.get();
}
