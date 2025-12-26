// lib/core/formatters.dart

/// نقطة جغرافية بسيطة
class GeoPoint {
  final double lat;
  final double lon;
  const GeoPoint(this.lat, this.lon);
  @override
  String toString() => '($lat,$lon)';
}

/// أدوات تنسيق وتهيئة نصوص/أرقام/إحداثيات ملائمة للعربية.
class Formatters {
  Formatters._();

  /// تحويل كل الأرقام العربية (٠١٢٣...) والفارسية/الهندية الشرقية (۰۱۲۳...)
  /// إلى أرقام لاتينية (0-9)
  static String arabicToEnglishDigits(String input) {
    const arabicIndic = [
      '٠',
      '١',
      '٢',
      '٣',
      '٤',
      '٥',
      '٦',
      '٧',
      '٨',
      '٩'
    ]; // U+0660..U+0669
    const easternArabicIndic = [
      '۰',
      '۱',
      '۲',
      '۳',
      '۴',
      '۵',
      '۶',
      '۷',
      '۸',
      '۹'
    ]; // U+06F0..U+06F9
    for (var i = 0; i < 10; i++) {
      input = input.replaceAll(arabicIndic[i], i.toString());
      input = input.replaceAll(easternArabicIndic[i], i.toString());
    }
    return input;
  }

  /// تحويل الأرقام اللاتينية (0-9) إلى عربية (٠-٩).
  /// إن رغبت بالأرقام الشرقية (۰-۹) مرّر useEastern: true.
  static String englishToArabicDigits(String input, {bool useEastern = false}) {
    const arabicIndic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const easternArabicIndic = [
      '۰',
      '۱',
      '۲',
      '۳',
      '۴',
      '۵',
      '۶',
      '۷',
      '۸',
      '۹'
    ];
    final target = useEastern ? easternArabicIndic : arabicIndic;
    for (var i = 0; i < 10; i++) {
      input = input.replaceAll(i.toString(), target[i]);
    }
    return input;
  }

  /// إزالة التشكيل والمدود من النص العربي
  static String stripDiacritics(String input) {
    const diacritics = [
      '\u064B',
      '\u064C',
      '\u064D',
      '\u064E',
      '\u064F',
      '\u0650',
      '\u0651',
      '\u0652',
      '\u0653',
      '\u0654',
      '\u0655',
      '\u0670',
      'ـ'
    ];
    for (final d in diacritics) {
      input = input.replaceAll(d, '');
    }
    return input;
  }

  /// توحيد المسافات
  static String normalizeWhitespace(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// تنظيف عام للنص لغايات البحث (lowercase + إزالة تشكيل + أرقام لاتينية)
  static String normalizeForSearch(String input) {
    var s = arabicToEnglishDigits(input);
    s = stripDiacritics(s);
    s = s.toLowerCase();
    s = normalizeWhitespace(s);
    return s;
  }

  /// تطبيع رقم الهاتف إلى شكل موحّد (خاصة لليمن):
  /// - تحويل الأرقام إلى لاتينية
  /// - السماح فقط بـ + في البداية وبقية الرموز أرقام
  /// - نزع بادئة الدولة 967 (مع احتمالات +/00/0) إن وُجدت
  /// - نزع الأصفار الزائدة في البداية
  /// الناتج عادة يكون الرقم المحلي بدون صفر بادئ أو كود الدولة.
  static String normalizePhone(String input) {
    var s = arabicToEnglishDigits(input);

    // استبدال 00 ببداية دولية قياسية (+)
    if (s.startsWith('00')) {
      s = s.replaceFirst(RegExp(r'^00'), '+');
    }

    // السماح بـ + واحدة في البداية ثم أرقام فقط
    s = s.replaceAll(RegExp(r'[^\d\+]'), '');

    // إزالة كود الدولة اليمني 967 مع احتمالات مختلفة
    // +967 / 00967 / 0967 / 967 / 0 967
    s = s.replaceFirst(RegExp(r'^(\+?0{0,2}967)'), '');

    // إزالة الأصفار البادئة المتبقية
    s = s.replaceFirst(RegExp(r'^0+'), '');

    return s;
  }

  /// محاولة تحليل رقم عشري من نص قد يحتوي فواصل عربية/إنجليزية وأرقام عربية.
  static double? tryParseDouble(String input) {
    var s = arabicToEnglishDigits(input);
    s = s.trim();

    // استبدال الفاصلة العربية أو الإنجليزية بفاصل عشري موحّد عند الحاجة
    // مثال: "1,234.56" أو "1٬234٫56"
    s = s
        .replaceAll('٬', '') // U+066C Arabic Thousands Separator
        .replaceAll('٫', '.') // U+066B Arabic Decimal Separator
        .replaceAll(RegExp(r','), ''); // إزالة الفواصل الإنجليزية للألوف

    return double.tryParse(s);
  }

  /// محاولة تحليل إحداثيات من نص: "lat,lon" (تدعم الفاصلة العربية)، أو DMS.
  static GeoPoint? tryParseGeo(String input) {
    final s = normalizeWhitespace(arabicToEnglishDigits(input));

    // 1) عشري: "lat, lon" أو باستخدام الفاصلة العربية "،"
    final dec =
        RegExp(r'^\s*([+-]?\d+(?:\.\d+)?)\s*[,،]\s*([+-]?\d+(?:\.\d+)?)\s*$');
    final dm = dec.firstMatch(s);
    if (dm != null) {
      final lat = double.tryParse(dm.group(1)!);
      final lon = double.tryParse(dm.group(2)!);
      if (lat != null && lon != null) return GeoPoint(lat, lon);
    }

    // 2) DMS: 16°34'37.75" N 44°13'53.89" E
    // نقبل أيضًا بعض الرموز الشائعة مثل ″ و ’
    final dmsPattern = RegExp(
      r'(\d+)[°º:\s]+(\d+)['
      '’":s]+(d+(?:.d+)?)["″]?s*([NSns])[,;s]+'
      r'(\d+)[°º:\s]+(\d+)['
      '’":s]+(d+(?:.d+)?)["″]?s*([EWew])',
    );
    final m = dmsPattern.firstMatch(s);
    if (m != null) {
      final lat = _dmsToDecimal(
        deg: _toDouble(m.group(1)),
        min: _toDouble(m.group(2)),
        sec: _toDouble(m.group(3)),
        hemi: m.group(4),
      );
      final lon = _dmsToDecimal(
        deg: _toDouble(m.group(5)),
        min: _toDouble(m.group(6)),
        sec: _toDouble(m.group(7)),
        hemi: m.group(8),
      );
      if (lat != null && lon != null) return GeoPoint(lat, lon);
    }

    return null;
  }

  static double? _toDouble(String? s) => s == null ? null : double.tryParse(s);

  static double? _dmsToDecimal({
    double? deg,
    double? min,
    double? sec,
    String? hemi,
  }) {
    if (deg == null || min == null || sec == null) return null;
    var val = deg + (min / 60.0) + (sec / 3600.0);
    if (hemi != null) {
      final h = hemi.toUpperCase();
      if (h == 'S' || h == 'W') val = -val;
    }
    return val;
  }

  /// تحويل عشري إلى DMS (للعرض)
  static String formatDms(double value, {bool isLat = true}) {
    final hemiPos = isLat ? 'N' : 'E';
    final hemiNeg = isLat ? 'S' : 'W';
    final hemi = value >= 0 ? hemiPos : hemiNeg;

    final v = value.abs();
    final d = v.floor();
    final mFull = (v - d) * 60;
    final m = mFull.floor();
    final s = (mFull - m) * 60;

    String two(int n) => n.toString().padLeft(2, '0');
    final secStr = s.toStringAsFixed(2);

    return '$d°${two(m)}\'$secStr" $hemi';
  }

  /// تنسيق إحداثيات عشريتين إلى نص
  static String formatLatLon(double lat, double lon, {bool dms = false}) {
    if (!dms) {
      return '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';
    } else {
      final slat = formatDms(lat, isLat: true);
      final slon = formatDms(lon, isLat: false);
      return '$slat $slon';
    }
  }
}
