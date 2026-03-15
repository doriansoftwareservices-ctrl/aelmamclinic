// lib/utils/time.dart
//
// أدوات وتنسيقات زمنية موحّدة لواجهات الدردشة وسائر التطبيق.
//
// الميزات:
// - تنسيقات جاهزة لعرض وقت الرسائل في القائمة والفقاعات.
// - فواصل الأيام في شاشة الدردشة: "اليوم" / "أمس" / اسم اليوم / YYYY-MM-DD.
// - دوال مساعدة: نفس_اليوم، أمس، ضمن آخر N أيام، تحليل/تحويل ISO-UTC مرن.
// - إضافات اختيارية: صيغة نسبية مختصرة، تجميع حسب اليوم، نطاق وقت قصير، مدة H:MM:SS.
//
// ملاحظات:
// - جميع التنسيقات تُعرَض بالتوقيت المحلي للمستخدم.
// - تُحسم لغة النصوص من Intl.defaultLocale افتراضيًا مع دعم تمرير languageCode.
// - يُفضَّل التخزين/النقل بتوقيت UTC (استخدم toIsoUtc/parseDateFlexibleUtc).

library time_utils;

import 'package:aelmamclinic/utils/app_locale.dart';
import 'package:intl/intl.dart';

/// أسماء الأيام وفق Dart: Monday=1..Sunday=7.
const List<String> _kWeekdaysAr = <String>[
  'الإثنين',
  'الثلاثاء',
  'الأربعاء',
  'الخميس',
  'الجمعة',
  'السبت',
  'الأحد',
];

const List<String> _kWeekdaysEn = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String _resolvedLanguageCode([String? languageCode]) {
  return AppLocale.normalize(
    languageCode ?? Intl.defaultLocale ?? AppLocale.defaultLanguageCode,
  );
}

bool _useArabic([String? languageCode]) {
  return _resolvedLanguageCode(languageCode) == AppLocale.arabicLanguageCode;
}

String _todayLabel([String? languageCode]) =>
    _useArabic(languageCode) ? 'اليوم' : 'Today';

String _yesterdayLabel([String? languageCode]) =>
    _useArabic(languageCode) ? 'أمس' : 'Yesterday';

String _tomorrowLabel([String? languageCode]) =>
    _useArabic(languageCode) ? 'غدًا' : 'Tomorrow';

String _nowLabel([String? languageCode]) =>
    _useArabic(languageCode) ? 'الآن' : 'Now';

String _momentsLabel({required bool future, String? languageCode}) {
  if (_useArabic(languageCode)) {
    return future ? 'بعد لحظات' : _nowLabel(languageCode);
  }
  return future ? 'In moments' : _nowLabel(languageCode);
}

String _quantityUnitAr(int value, String singular, String dual, String plural) {
  if (value == 1) return singular;
  if (value == 2) return dual;
  return '$value $plural';
}

String _quantityUnitEn(int value, String singular, String plural) {
  return value == 1 ? '1 $singular' : '$value $plural';
}

String _relativeText({
  required int value,
  required String singularAr,
  required String dualAr,
  required String pluralAr,
  required String singularEn,
  required String pluralEn,
  required bool future,
  String? languageCode,
}) {
  if (_useArabic(languageCode)) {
    final unit = _quantityUnitAr(value, singularAr, dualAr, pluralAr);
    return future ? 'بعد $unit' : 'منذ $unit';
  }
  final unit = _quantityUnitEn(value, singularEn, pluralEn);
  return future ? 'In $unit' : '$unit ago';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// -------- التحليل/التحويل --------

/// يحوِّل أي قيمة (DateTime/String/num) إلى DateTime UTC إن أمكن، وإلا null.
/// - String: يُتوقّع ISO-8601 (سيتم تحليلها ثم تحويلها إلى UTC).
/// - DateTime: تُعاد بعد تحويلها إلى UTC.
/// - غير ذلك: null.
DateTime? parseDateFlexibleUtc(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v.toUtc();
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  try {
    return DateTime.parse(s).toUtc();
  } catch (_) {
    return null;
  }
}

/// مثل [parseDateFlexibleUtc] لكن تُعاد محلية (toLocal) إن أمكن.
DateTime? parseDateFlexibleLocal(dynamic v) {
  final dt = parseDateFlexibleUtc(v);
  return dt?.toLocal();
}

/// يحوّل التاريخ إلى نص ISO-8601 UTC أو null.
String? toIsoUtc(DateTime? dt) => dt?.toUtc().toIso8601String();

/// تحويل Unix epoch بالميلي ثانية إلى UTC.
DateTime unixMsToUtc(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// تحويل Unix epoch بالثواني إلى UTC.
DateTime unixSecToUtc(int sec) =>
    DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true);

/// -------- لبنات منطقية --------

/// بداية اليوم (محليًا).
DateTime startOfDayLocal(DateTime dt) {
  final l = dt.toLocal();
  return DateTime(l.year, l.month, l.day);
}

/// نهاية اليوم (محليًا).
DateTime endOfDayLocal(DateTime dt) {
  final s = startOfDayLocal(dt);
  return s
      .add(const Duration(days: 1))
      .subtract(const Duration(milliseconds: 1));
}

/// هل التاريخ (بعد تحويله إلى محلي) هو اليوم؟
bool isToday(DateTime dt, {DateTime? now}) {
  final _now = (now ?? DateTime.now()).toLocal();
  final d = dt.toLocal();
  final a = DateTime(_now.year, _now.month, _now.day);
  final b = DateTime(d.year, d.month, d.day);
  return a == b;
}

/// هل التاريخ (بعد تحويله إلى محلي) هو أمس؟
bool isYesterday(DateTime dt, {DateTime? now}) {
  final _now = (now ?? DateTime.now()).toLocal();
  final d = dt.toLocal();
  final yesterday = DateTime(_now.year, _now.month, _now.day)
      .subtract(const Duration(days: 1));
  final dd = DateTime(d.year, d.month, d.day);
  return dd == yesterday;
}

/// هل التاريخ ضمن آخر [days] أيام بالنسبة إلى الآن (محليًا)؟
bool isWithinLastDays(DateTime dt, int days, {DateTime? now}) {
  final _now = (now ?? DateTime.now()).toLocal();
  final d = dt.toLocal();
  return _now.difference(d).inDays < days;
}

/// هل التاريخان في نفس اليوم (محليًا)؟
bool isSameLocalDay(DateTime a, DateTime b) {
  final al = a.toLocal();
  final bl = b.toLocal();
  return al.year == bl.year && al.month == bl.month && al.day == bl.day;
}

/// -------- تنسيقات بسيطة --------

/// HH:mm بالتوقيت المحلي.
String formatHhMm(DateTime dt) {
  final l = dt.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

/// YYYY-MM-DD بالتوقيت المحلي.
String formatYmd(DateTime dt) {
  final l = dt.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)}';
}

/// YYYY-MM-DD HH:mm (محلي).
String formatYmdHhMm(DateTime dt) => '${formatYmd(dt)} ${formatHhMm(dt)}';

/// اسم اليوم للتاريخ المحدد (محليًا) وفق اللغة الحالية أو الممررة.
String weekdayName(DateTime dt, {String? languageCode}) {
  final l = dt.toLocal();
  final idx = (l.weekday - 1).clamp(0, _kWeekdaysAr.length - 1);
  final names = _useArabic(languageCode) ? _kWeekdaysAr : _kWeekdaysEn;
  return names[idx];
}

/// توافق خلفي للاستخدامات القديمة.
String weekdayNameAr(DateTime dt) =>
    weekdayName(dt, languageCode: AppLocale.arabicLanguageCode);

/// -------- تنسيقات واجهة الدردشة --------

/// تنسيق افتراضي لقائمة المحادثات:
/// - إن كان اليوم: HH:mm
/// - إن كان أمس (اختياريًا عبر useYesterdayLabel): "أمس"
/// - خلال آخر 7 أيام: اسم اليوم
/// - غير ذلك: YYYY-MM-DD
String formatChatListTimestamp(
  DateTime dt, {
  DateTime? now,
  bool useYesterdayLabel = false,
  String? languageCode,
}) {
  if (isToday(dt, now: now)) {
    return formatHhMm(dt);
  } else if (useYesterdayLabel && isYesterday(dt, now: now)) {
    return _yesterdayLabel(languageCode);
  } else if (isWithinLastDays(dt, 7, now: now)) {
    return weekdayName(dt, languageCode: languageCode);
  } else {
    return formatYmd(dt);
  }
}

/// تنسيق مختصر مناسب تحت فقاعات الرسائل (نفس قاعدة القائمة).
String formatMessageTimestamp(
  DateTime dt, {
  DateTime? now,
  String? languageCode,
}) =>
    formatChatListTimestamp(dt, now: now, languageCode: languageCode);

/// ترويسة فواصل الأيام في شاشة الدردشة (على نمط واتساب):
/// - اليوم  → "اليوم"
/// - أمس    → "أمس"
/// - خلال الأسبوع → اسم اليوم
/// - غير ذلك → YYYY-MM-DD
String formatDayHeader(DateTime dt, {DateTime? now, String? languageCode}) {
  if (isToday(dt, now: now)) return _todayLabel(languageCode);
  if (isYesterday(dt, now: now)) return _yesterdayLabel(languageCode);
  if (isWithinLastDays(dt, 7, now: now)) {
    return weekdayName(dt, languageCode: languageCode);
  }
  return formatYmd(dt);
}

/// -------- صيغة نسبية عربية مبسّطة --------
/// أمثلة: "الآن"، "منذ دقيقة"، "منذ 5 دقائق"، "منذ ساعة"، "منذ ساعتين"، "منذ 5 ساعات",
/// "أمس"، "منذ 3 أيام"، وبعد أسبوع نرجع YYYY-MM-DD.
/// تدعم المستقبل أيضًا: "بعد دقيقة"، "بعد 3 ساعات"...
String formatRelative(DateTime dt, {DateTime? now, String? languageCode}) {
  final _now = (now ?? DateTime.now()).toLocal();
  final d = dt.toLocal();
  final diff = _now.difference(d);
  final future = diff.isNegative;
  final dur = diff.abs();

  if (dur.inSeconds <= 10) {
    return _momentsLabel(future: future, languageCode: languageCode);
  }

  if (dur.inMinutes < 1) {
    return _relativeText(
      value: dur.inSeconds,
      singularAr: 'ثانية',
      dualAr: 'ثانيتين',
      pluralAr: 'ثوانٍ',
      singularEn: 'second',
      pluralEn: 'seconds',
      future: future,
      languageCode: languageCode,
    );
  }

  if (dur.inMinutes < 60) {
    return _relativeText(
      value: dur.inMinutes,
      singularAr: 'دقيقة',
      dualAr: 'دقيقتين',
      pluralAr: 'دقائق',
      singularEn: 'minute',
      pluralEn: 'minutes',
      future: future,
      languageCode: languageCode,
    );
  }

  if (dur.inHours < 24) {
    return _relativeText(
      value: dur.inHours,
      singularAr: 'ساعة',
      dualAr: 'ساعتين',
      pluralAr: 'ساعات',
      singularEn: 'hour',
      pluralEn: 'hours',
      future: future,
      languageCode: languageCode,
    );
  }

  // أمس/غد
  if (isYesterday(d, now: _now)) return _yesterdayLabel(languageCode);
  final tomorrow = startOfDayLocal(_now).add(const Duration(days: 1));
  if (isSameLocalDay(d, tomorrow)) return _tomorrowLabel(languageCode);

  if (dur.inDays < 7) {
    return _relativeText(
      value: dur.inDays,
      singularAr: 'يوم',
      dualAr: 'يومين',
      pluralAr: 'أيام',
      singularEn: 'day',
      pluralEn: 'days',
      future: future,
      languageCode: languageCode,
    );
  }

  return formatYmd(dt);
}

String formatRelativeAr(DateTime dt, {DateTime? now}) =>
    formatRelative(dt, now: now, languageCode: AppLocale.arabicLanguageCode);

/// -------- صيغ إضافية اختيارية --------

/// صيغة نسبية مختصرة جداً: "الآن" / "5ث" / "2د" / "3س" / "أمس" / "4ي" / تاريخ.
String formatRelativeCompact(
  DateTime dt, {
  DateTime? now,
  String? languageCode,
}) {
  final _now = (now ?? DateTime.now()).toLocal();
  final d = dt.toLocal();
  final diff = _now.difference(d);
  final future = diff.isNegative;
  final dur = diff.abs();

  String unit(num v, String u) => '${v.toStringAsFixed(0)}$u';

  if (dur.inSeconds <= 10) {
    return _momentsLabel(future: future, languageCode: languageCode);
  }
  if (dur.inMinutes < 1)
    return future
        ? (_useArabic(languageCode)
            ? 'بعد ${unit(dur.inSeconds, "ث")}'
            : 'In ${unit(dur.inSeconds, "s")}')
        : unit(dur.inSeconds, _useArabic(languageCode) ? 'ث' : 's');
  if (dur.inMinutes < 60)
    return future
        ? (_useArabic(languageCode)
            ? 'بعد ${unit(dur.inMinutes, "د")}'
            : 'In ${unit(dur.inMinutes, "m")}')
        : unit(dur.inMinutes, _useArabic(languageCode) ? 'د' : 'm');
  if (dur.inHours < 24)
    return future
        ? (_useArabic(languageCode)
            ? 'بعد ${unit(dur.inHours, "س")}'
            : 'In ${unit(dur.inHours, "h")}')
        : unit(dur.inHours, _useArabic(languageCode) ? 'س' : 'h');
  if (isYesterday(d, now: _now)) return _yesterdayLabel(languageCode);
  if (dur.inDays < 7)
    return future
        ? (_useArabic(languageCode)
            ? 'بعد ${unit(dur.inDays, "ي")}'
            : 'In ${unit(dur.inDays, "d")}')
        : unit(dur.inDays, _useArabic(languageCode) ? 'ي' : 'd');
  return formatYmd(dt);
}

String formatRelativeCompactAr(DateTime dt, {DateTime? now}) => formatRelativeCompact(
      dt,
      now: now,
      languageCode: AppLocale.arabicLanguageCode,
    );

/// نطاق وقت قصير في نفس اليوم: "10:20–11:05".
/// إن كان التاريخ مختلفًا: يُعاد "YYYY-MM-DD HH:mm – YYYY-MM-DD HH:mm".
String formatRangeShort(DateTime a, DateTime b) {
  final sameDay = isSameLocalDay(a, b);
  if (sameDay) {
    return '${formatHhMm(a)}–${formatHhMm(b)}';
  }
  return '${formatYmdHhMm(a)} – ${formatYmdHhMm(b)}';
}

/// صيغة مدة: H:MM:SS (أو M:SS إن كانت أقل من ساعة).
String formatHms(Duration d) {
  final totalSeconds = d.inSeconds.abs();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${_two(minutes)}:${_two(seconds)}';
  }
  return '${minutes}:${_two(seconds)}';
}

/// -------- تجميع حسب اليوم (لفواصل اليوم) --------

/// مفتاح يوم على شكل "YYYY-MM-DD" (محليًا) — مناسب كمفتاح قسم/مجموعة.
String daySectionKey(DateTime dt) => formatYmd(dt);

/// هل يجب إدراج فاصل يوم جديد بين [prev] و [curr]؟
bool shouldInsertDayDivider(DateTime? prev, DateTime curr) {
  if (prev == null) return true;
  return !isSameLocalDay(prev, curr);
}

/// -------- Extensions مفيدة --------

extension DateX on DateTime {
  bool get isTodayLocal => isToday(this);
  bool get isYesterdayLocal => isYesterday(this);

  bool sameLocalDayAs(DateTime other) => isSameLocalDay(this, other);

  String toIsoUtcString() => toIsoUtc(this) ?? '';
}
