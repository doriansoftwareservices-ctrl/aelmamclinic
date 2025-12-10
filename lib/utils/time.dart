// lib/utils/time.dart
//
// أدوات وتنسيقات زمنية موحّدة لواجهات الدردشة وسائر التطبيق.
//
// الميزات:
// - تنسيقات جاهزة لعرض وقت الرسائل في القائمة والفقاعات.
// - فواصل الأيام في شاشة الدردشة: "اليوم" / "أمس" / اسم اليوم / YYYY-MM-DD.
// - دوال مساعدة: نفس_اليوم، أمس، ضمن آخر N أيام، تحليل/تحويل ISO-UTC مرن.
// - بدون الاعتماد على حزمة intl.
// - إضافات اختيارية: صيغة نسبية مختصرة، تجميع حسب اليوم، نطاق وقت قصير، مدة H:MM:SS.
//
// ملاحظات:
// - جميع التنسيقات تُعرَض بالتوقيت المحلي للمستخدم.
// - يُفضَّل التخزين/النقل بتوقيت UTC (استخدم toIsoUtc/parseDateFlexibleUtc).

library time_utils;

/// أسماء الأيام بالعربية وفق Dart: Monday=1..Sunday=7.
const List<String> _kWeekdaysAr = <String>[
  'الإثنين',
  'الثلاثاء',
  'الأربعاء',
  'الخميس',
  'الجمعة',
  'السبت',
  'الأحد',
];

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

/// اسم اليوم بالعربية للتاريخ المحدد (محليًا).
String weekdayNameAr(DateTime dt) {
  final l = dt.toLocal();
  final idx = (l.weekday - 1).clamp(0, _kWeekdaysAr.length - 1);
  return _kWeekdaysAr[idx];
}

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
}) {
  if (isToday(dt, now: now)) {
    return formatHhMm(dt);
  } else if (useYesterdayLabel && isYesterday(dt, now: now)) {
    return 'أمس';
  } else if (isWithinLastDays(dt, 7, now: now)) {
    return weekdayNameAr(dt);
  } else {
    return formatYmd(dt);
  }
}

/// تنسيق مختصر مناسب تحت فقاعات الرسائل (نفس قاعدة القائمة).
String formatMessageTimestamp(DateTime dt, {DateTime? now}) =>
    formatChatListTimestamp(dt, now: now);

/// ترويسة فواصل الأيام في شاشة الدردشة (على نمط واتساب):
/// - اليوم  → "اليوم"
/// - أمس    → "أمس"
/// - خلال الأسبوع → اسم اليوم
/// - غير ذلك → YYYY-MM-DD
String formatDayHeader(DateTime dt, {DateTime? now}) {
  if (isToday(dt, now: now)) return 'اليوم';
  if (isYesterday(dt, now: now)) return 'أمس';
  if (isWithinLastDays(dt, 7, now: now)) return weekdayNameAr(dt);
  return formatYmd(dt);
}

/// -------- صيغة نسبية عربية مبسّطة --------
/// أمثلة: "الآن"، "منذ دقيقة"، "منذ 5 دقائق"، "منذ ساعة"، "منذ ساعتين"، "منذ 5 ساعات",
/// "أمس"، "منذ 3 أيام"، وبعد أسبوع نرجع YYYY-MM-DD.
/// تدعم المستقبل أيضًا: "بعد دقيقة"، "بعد 3 ساعات"...
String formatRelativeAr(DateTime dt, {DateTime? now}) {
  final _now = (now ?? DateTime.now()).toLocal();
  final d = dt.toLocal();
  final diff = _now.difference(d);
  final future = diff.isNegative;
  final dur = diff.abs();

  String past(String s) => 'منذ $s';
  String futureS(String s) => 'بعد $s';

  String choose(int value, String singular, String dual, String plural) {
    if (value == 1) return singular;
    if (value == 2) return dual;
    return '$value $plural';
  }

  if (dur.inSeconds <= 10) return future ? 'بعد لحظات' : 'الآن';

  if (dur.inMinutes < 1) {
    final txt = choose(dur.inSeconds, 'ثانية', 'ثانيتين', 'ثوانٍ');
    return future ? futureS(txt) : past(txt);
  }

  if (dur.inMinutes < 60) {
    final txt = choose(dur.inMinutes, 'دقيقة', 'دقيقتين', 'دقائق');
    return future ? futureS(txt) : past(txt);
  }

  if (dur.inHours < 24) {
    final txt = choose(dur.inHours, 'ساعة', 'ساعتين', 'ساعات');
    return future ? futureS(txt) : past(txt);
  }

  // أمس/غد
  if (isYesterday(d, now: _now)) return 'أمس';
  final tomorrow = startOfDayLocal(_now).add(const Duration(days: 1));
  if (isSameLocalDay(d, tomorrow)) return 'غدًا';

  if (dur.inDays < 7) {
    final txt = choose(dur.inDays, 'يوم', 'يومين', 'أيام');
    return future ? futureS(txt) : past(txt);
  }

  return formatYmd(dt);
}

/// -------- صيغ إضافية اختيارية --------

/// صيغة نسبية مختصرة جداً: "الآن" / "5ث" / "2د" / "3س" / "أمس" / "4ي" / تاريخ.
String formatRelativeCompactAr(DateTime dt, {DateTime? now}) {
  final _now = (now ?? DateTime.now()).toLocal();
  final d = dt.toLocal();
  final diff = _now.difference(d);
  final future = diff.isNegative;
  final dur = diff.abs();

  String unit(num v, String u) => '${v.toStringAsFixed(0)}$u';

  if (dur.inSeconds <= 10) return future ? 'بعد لحظات' : 'الآن';
  if (dur.inMinutes < 1)
    return future
        ? 'بعد ${unit(dur.inSeconds, "ث")}'
        : unit(dur.inSeconds, 'ث');
  if (dur.inMinutes < 60)
    return future
        ? 'بعد ${unit(dur.inMinutes, "د")}'
        : unit(dur.inMinutes, 'د');
  if (dur.inHours < 24)
    return future ? 'بعد ${unit(dur.inHours, "س")}' : unit(dur.inHours, 'س');
  if (isYesterday(d, now: _now)) return 'أمس';
  if (dur.inDays < 7)
    return future ? 'بعد ${unit(dur.inDays, "ي")}' : unit(dur.inDays, 'ي');
  return formatYmd(dt);
}

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
