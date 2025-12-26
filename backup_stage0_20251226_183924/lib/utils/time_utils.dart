// lib/utils/time_utils.dart
//
// أدوات فحص/مزامنة الوقت واكتشاف العبث بساعة الجهاز.
// - تحقّق محلي (رجوع بالوقت أو قفزة كبيرة للأمام).
// - فحص عبر NTP مع أخذ عينات متعدّدة لاستخراج وسيط الإزاحة (offset).
// - تخزين الإزاحة مع TTL لتجنّب الاتصالات المتكرّرة.
// - nowTrusted(): وقت موثوق = وقت الجهاز + الإزاحة المخبّأة.
// - حارس تزامن يمنع سباق طلبات NTP.
//
// المتطلبات في pubspec.yaml:
//   dependencies:
//     shared_preferences: ^2.2.0
//     ntp: ^2.0.0

import 'dart:async';
import 'dart:math';

import 'package:ntp/ntp.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TimeUtils {
  TimeUtils._();

  // مفاتيح التخزين
  static const String _lastCheckKey = 'time:last_device_check_iso';
  static const String _offsetMsKey = 'time:last_ntp_offset_ms';
  static const String _offsetAtKey = 'time:last_ntp_offset_at_iso';

  /// أقصى تقدّم مسموح به بين تحققَين محليين (افتراضي: يوم).
  static const Duration _defaultMaxForwardDrift = Duration(days: 1);

  /// صلاحية الإزاحة المخزّنة (افتراضي: 6 ساعات).
  static const Duration _defaultOffsetTtl = Duration(hours: 6);

  /// مهمة NTP جارية (حارس تزامن).
  static Future<Duration?>? _inflightOffset;

  /*──────────────────── API الأساسية ────────────────────*/

  /// هل تم العبث بوقت الجهاز مقارنةً بآخر تحقق محلي؟
  /// - True إن عاد الوقت للخلف أو تقدّم أكثر من [maxForwardDrift].
  /// - لا تحفظ طابعًا جديدًا تلقائيًا؛ استدعِ [updateLastCheck] بنفسك في نقاط مناسبة (onResume مثلاً).
  static Future<bool> isDeviceTimeTampered({
    Duration maxForwardDrift = _defaultMaxForwardDrift,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_lastCheckKey);
    if (last == null || last.isEmpty) return false;

    DateTime? lastCheck;
    try {
      lastCheck = DateTime.parse(last);
    } catch (_) {
      return false; // لو تالف، تجاهل بدل إطلاق استثناء
    }

    final now = DateTime.now();
    final diff = now.difference(lastCheck);

    // رجوع بالوقت (سالب) أو تقدّم مفرط
    return diff.isNegative || diff > maxForwardDrift;
  }

  /// يحصل على الوقت الدقيق من NTP (تاريخ خادوم) — استدعاء مباشر واحد.
  static Future<DateTime> getNetworkTime() async {
    // NTP.now() يُعيد DateTime؛ نحول إلى UTC للحياد عن المنطقة الزمنية.
    final t = await NTP.now();
    return t.toUtc();
  }

  /// يحسب إزاحة الجهاز مقابل NTP: (NTP - Device).
  /// قيمة موجبة تعني أن NTP متقدّم على جهازك.
  static Future<Duration> getNtpOffsetOnce() async {
    final ntp = await getNetworkTime();
    final device = DateTime.now().toUtc();
    return ntp.difference(device);
  }

  /// يأخذ عدة عينات NTP ويعيد **وسيط** الإزاحة لتقليل الضجيج.
  static Future<Duration> sampleNtpOffset({
    int samples = 3,
    Duration between = const Duration(milliseconds: 180),
  }) async {
    assert(samples >= 1);
    final offsets = <int>[];

    for (var i = 0; i < samples; i++) {
      final d = await getNtpOffsetOnce();
      offsets.add(d.inMilliseconds);
      if (i < samples - 1) {
        await Future<void>.delayed(between);
      }
    }

    offsets.sort();
    final ms = offsets[offsets.length ~/ 2]; // وسيط
    return Duration(milliseconds: ms);
  }

  /// يعيد الإزاحة المخبّأة إن كانت غير منتهية الصلاحية، وإلا يجلبها ويخزّنها.
  static Future<Duration?> ensureNtpOffset({
    Duration ttl = _defaultOffsetTtl,
    int samples = 3,
    bool forceRefresh = false,
  }) async {
    // حاول القراءة من الكاش
    if (!forceRefresh) {
      final cached = await _readCachedOffset(ttl: ttl);
      if (cached != null) return cached;
    }

    // امنع العمل المتوازي
    _inflightOffset ??= _fetchAndCacheOffset(ttl: ttl, samples: samples);
    try {
      return await _inflightOffset;
    } finally {
      _inflightOffset = null;
    }
  }

  /// يعيد true إذا كان الانجراف المطلق عن NTP أكبر من [allowedDrift].
  /// يستخدم الكاش متى أمكن لتقليل الاتصال؛ اضبط forceRefresh لو احتجت قياسًا لحظيًا.
  static Future<bool> isNetworkTimeTampered({
    Duration allowedDrift = const Duration(minutes: 5),
    Duration ttl = _defaultOffsetTtl,
    int samples = 3,
    bool forceRefresh = false,
  }) async {
    try {
      final off = await ensureNtpOffset(
        ttl: ttl,
        samples: samples,
        forceRefresh: forceRefresh,
      );
      if (off == null) return true; // فشل الجلب = غير موثوق
      return off.abs() > allowedDrift;
    } catch (_) {
      return true; // فشل الاتصال = اعتبر غير موثوق
    }
  }

  /// وقت موثوق: وقت الجهاز + الإزاحة المخبأة إن وُجدت ولم تنتهِ.
  /// إن لم تتوفر إزاحة صالحة:
  ///  - إن كان [requireNetwork] = true سيُرمى استثناء.
  ///  - غير ذلك يُعاد وقت الجهاز.
  static Future<DateTime> nowTrusted({
    bool requireNetwork = false,
    Duration ttl = _defaultOffsetTtl,
  }) async {
    final off = await _readCachedOffset(ttl: ttl);
    if (off != null) {
      return DateTime.now().add(off);
    }
    if (requireNetwork) {
      // حاول جلبها ثم أعِد
      final fresh = await ensureNtpOffset(ttl: ttl);
      if (fresh == null) {
        throw StateError('Failed to obtain NTP offset');
      }
      return DateTime.now().add(fresh);
    }
    return DateTime.now();
  }

  /// حدّث طابع آخر تحقق محلي (يفضّل استدعاؤها عند تشغيل التطبيق/عودة الواجهة للأمام).
  static Future<void> updateLastCheck([DateTime? now]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _lastCheckKey,
      (now ?? DateTime.now()).toIso8601String(),
    );
  }

  /// مسح الكاش/الحالة المخزّنة (للdebug أو إعادة تهيئة).
  static Future<void> clearCachedState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastCheckKey);
    await prefs.remove(_offsetMsKey);
    await prefs.remove(_offsetAtKey);
  }

  /// فحص شامل يُعيد نتيجة موحّدة تحتوي كل الأعلام/القيَم.
  static Future<TimeCheckResult> checkConsistency({
    Duration localForwardDrift = _defaultMaxForwardDrift,
    Duration networkAllowedDrift = const Duration(minutes: 5),
    Duration ttl = _defaultOffsetTtl,
    int samples = 3,
    bool forceNetworkRefresh = false,
  }) async {
    final deviceTampered =
        await isDeviceTimeTampered(maxForwardDrift: localForwardDrift);
    final offset = await ensureNtpOffset(
      ttl: ttl,
      samples: samples,
      forceRefresh: forceNetworkRefresh,
    );
    final networkTampered =
        offset == null ? true : offset.abs() > networkAllowedDrift;

    return TimeCheckResult(
      deviceBackOrTooForward: deviceTampered,
      ntpOffset: offset,
      networkDriftExceeded: networkTampered,
    );
  }

  /*──────────────────── داخلي ────────────────────*/

  static Future<Duration?> _fetchAndCacheOffset({
    required Duration ttl,
    required int samples,
  }) async {
    try {
      final off = await sampleNtpOffset(samples: max(1, samples));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_offsetMsKey, off.inMilliseconds);
      await prefs.setString(_offsetAtKey, DateTime.now().toIso8601String());
      return off;
    } catch (_) {
      return null;
    }
  }

  static Future<Duration?> _readCachedOffset({required Duration ttl}) async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_offsetMsKey);
    final atIso = prefs.getString(_offsetAtKey);
    if (ms == null || atIso == null || atIso.isEmpty) return null;

    DateTime at;
    try {
      at = DateTime.parse(atIso);
    } catch (_) {
      return null;
    }

    if (DateTime.now().difference(at) > ttl) return null;
    return Duration(milliseconds: ms);
    // ملاحظة: قد يكون offset سالبًا أو موجبًا—نُعيده كما هو.
  }
}

/// نتيجة فحص الوقت الموحدة.
class TimeCheckResult {
  /// العبث محليًّا (رجوع/قفزة كبيرة للأمام وفق آخر تحقق محلي).
  final bool deviceBackOrTooForward;

  /// فرق NTP (NTP - Device). قد يكون null إن فشل الاتصال.
  final Duration? ntpOffset;

  /// هل تجاوز فرق NTP الحد المسموح؟
  final bool networkDriftExceeded;

  bool get anyTamper => deviceBackOrTooForward || networkDriftExceeded;

  const TimeCheckResult({
    required this.deviceBackOrTooForward,
    required this.ntpOffset,
    required this.networkDriftExceeded,
  });

  @override
  String toString() => 'TimeCheckResult(deviceTamper=$deviceBackOrTooForward, '
      'offset=${ntpOffset?.inMilliseconds}ms, '
      'networkTamper=$networkDriftExceeded)';
}
