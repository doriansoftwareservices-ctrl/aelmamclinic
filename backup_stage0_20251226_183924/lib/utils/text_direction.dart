// lib/utils/text_direction.dart
//
// أدوات ذكية لتحديد اتجاه النص (RTL/LTR) والتعامل مع الحالات الشائعة:
// - نص عربي/إنجليزي مختلط
// - عناوين بريد إلكتروني وروابط (تُعرض LTR دائمًا)
// - أرقام ورموز محايدة
//
// لا تعتمد على Flutter Widgets؛ نستخدم فقط ui.TextDirection لتهيئة
// عناصر الواجهة في مكان الاستدعاء.
//
// أمثلة استخدام:
//   final dir = textDirectionFor('example@site.com'); // LTR
//   final dir = textDirectionFor('مرحبا');            // RTL
//   final wrapped = bidiWrap('example@site.com', ui.TextDirection.ltr);
//   final isEmail = isEmailish('a@b.com'); // true
//
// ملاحظة:
// - افتراض الاتجاه الافتراضي RTL لواجهة عربية عند التساوي.
// - يمكن تغيير هذا الافتراض بتمرير defaultDirection.

library text_direction_utils;

import 'dart:ui' as ui;

/// نطاقات حروف عربية (قوية RTL).
/// تشمل العربية الأساسية والموسّعة وعرض التقديم.
final RegExp _rxArabic = RegExp(
  r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
);

/// حروف لاتينية (قوية LTR).
final RegExp _rxLatin = RegExp(r'[A-Za-z]');

/// أرقام (نضيف الغربية 0-9 والعربية ٠-٩ والفارسية ۰-۹).
final RegExp _rxDigits = RegExp(r'[0-9\u0660-\u0669\u06F0-\u06F9]');

/// بريد إلكتروني تقريبي.
final RegExp _rxEmail = RegExp(
  r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
  caseSensitive: false,
);

/// رابط/URL تقريبي.
final RegExp _rxUrl = RegExp(
  r'^(https?:\/\/|www\.)[^\s]+$',
  caseSensitive: false,
);

/// محارف تحكم اتجاهية (BiDi controls) — مفيدة للتنظيف.
const String _lri = '\u2066'; // Left-to-Right Isolate
const String _rli = '\u2067'; // Right-to-Left Isolate
const String _pdi = '\u2069'; // Pop Directional Isolate
const String _lrm = '\u200E'; // Left-to-Right Mark
const String _rlm = '\u200F'; // Right-to-Left Mark
const String _lre = '\u202A'; // Left-to-Right Embedding
const String _rle = '\u202B'; // Right-to-Left Embedding
const String _pdf = '\u202C'; // Pop Directional Formatting

/// هل السلسلة تبدو كإيميل؟
bool isEmailish(String s) => _rxEmail.hasMatch(s.trim());

/// هل السلسلة تبدو كعنوان URL؟
bool isUrlish(String s) => _rxUrl.hasMatch(s.trim());

/// هل تحتوي السلسلة على حروف RTL قوية؟
bool hasStrongRtl(String s) => _rxArabic.hasMatch(s);

/// هل تحتوي السلسلة على حروف LTR قوية؟
bool hasStrongLtr(String s) => _rxLatin.hasMatch(s);

/// هل السلسلة كلها أرقام/مسافات/رموز محايدة (دون حروف قوية)؟
bool isPurelyNeutral(String s) {
  if (s.trim().isEmpty) return true;
  if (hasStrongRtl(s) || hasStrongLtr(s)) return false;
  final stripped = s.replaceAll(_rxDigits, '').trim();
  return !hasStrongRtl(stripped) && !hasStrongLtr(stripped);
}

/// يقرر اتجاه النص اعتمادًا على محتواه.
/// - الإيميل/الرابط → LTR.
/// - إن كانت RTL فقط → RTL.
/// - إن كانت LTR فقط → LTR.
/// - إن كان مختلطًا → يُفضَّل RTL لتطبيق عربي (إلا إن مررت defaultDirection=LTR).
ui.TextDirection textDirectionFor(
  String text, {
  ui.TextDirection defaultDirection = ui.TextDirection.rtl,
  bool treatEmailAndUrlAsLtr = true,
}) {
  final s = text.trim();
  if (s.isEmpty) return defaultDirection;

  if (treatEmailAndUrlAsLtr && (isEmailish(s) || isUrlish(s))) {
    return ui.TextDirection.ltr;
  }

  final rtl = hasStrongRtl(s);
  final ltr = hasStrongLtr(s);

  if (rtl && !ltr) return ui.TextDirection.rtl;
  if (ltr && !rtl) return ui.TextDirection.ltr;

  // مختلط أو محايد: استخدم الاتجاه الافتراضي.
  return defaultDirection;
}

/// يعيد الاتجاه القوي الأول في النص (إن وُجد)، وإلا يعيد null.
ui.TextDirection? firstStrongDirection(String text) {
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (_rxArabic.hasMatch(ch)) return ui.TextDirection.rtl;
    if (_rxLatin.hasMatch(ch)) return ui.TextDirection.ltr;
  }
  return null;
}

/// يلف النص بعلامات عزل اتجاهية (BiDi isolates) لتفادي التداخل داخل أسطر RTL/LTR.
/// - يستخدم LRI (U+2066) / RLI (U+2067) مع PDI (U+2069).
/// هذا مفيد عند تضمين إيميل (LTR) داخل واجهة RTL أو العكس.
String bidiWrap(String text, ui.TextDirection direction) {
  if (text.isEmpty) return text;
  return (direction == ui.TextDirection.ltr)
      ? '$_lri$text$_pdi'
      : '$_rli$text$_pdi';
}

/// يضمن عرض السلسلة LTR داخل سياق RTL (بوضع LRI…PDI).
String ensureLtr(String text) => bidiWrap(text, ui.TextDirection.ltr);

/// يضمن عرض السلسلة RTL داخل سياق LTR (بوضع RLI…PDI).
String ensureRtl(String text) => bidiWrap(text, ui.TextDirection.rtl);

/// يقرر الاتجاه ثم يلف النص تلقائيًا بعلامات العزل المناسبة.
/// مفيد عند عرض نصوص قد تكون بريد/رابط/عربي… داخل عناصر RTL.
String autoBidiWrap(
  String text, {
  ui.TextDirection defaultDirection = ui.TextDirection.rtl,
  bool treatEmailAndUrlAsLtr = true,
}) {
  final dir = textDirectionFor(
    text,
    defaultDirection: defaultDirection,
    treatEmailAndUrlAsLtr: treatEmailAndUrlAsLtr,
  );
  return bidiWrap(text, dir);
}

/// نسخة "خفيفة" تعيد LTR لو كان بريدًا/رابطًا أو يحوي أحرفًا لاتينية فقط.
/// وإلا تُعيد RTL. تفيد لاختيار Directionality عند البناء.
ui.TextDirection ltrIfEmailOrLatinElseRtl(String text) {
  final s = text.trim();
  if (s.isEmpty) return ui.TextDirection.rtl;
  if (isEmailish(s) || isUrlish(s)) return ui.TextDirection.ltr;
  if (hasStrongLtr(s) && !hasStrongRtl(s)) return ui.TextDirection.ltr;
  return ui.TextDirection.rtl;
}

/// إزالة محارف التحكم الاتجاهية من النص (لأغراض النسخ/البحث/المقارنة).
String stripBidiControls(String text) {
  if (text.isEmpty) return text;
  const controls = [
    _lri,
    _rli,
    _pdi,
    _lrm,
    _rlm,
    _lre,
    _rle,
    _pdf,
  ];
  var out = text;
  for (final c in controls) {
    out = out.replaceAll(c, '');
  }
  return out;
}

/// قطع نص طويل مع مراعاة اتجاه افتراضي عند التساوي.
/// (أداة صغيرة بديلة لـ TextOverflow.ellipsis في غير الواجهات)
String safeEllipsis(
  String text,
  int maxChars, {
  ui.TextDirection? resolvedDirection,
}) {
  if (text.length <= maxChars) return text;
  // يمكن لاحقًا استخدام علامة U+2026 (…) بدل الثلاث نقاط.
  return text.substring(0, maxChars).trimRight() + '…';
}
