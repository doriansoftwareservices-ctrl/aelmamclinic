// lib/core/validators.dart

import 'formatters.dart';

/// مُتحقّقات الحقول (Validators) برسائل عربية واضحة.
/// استخدمها داخل TextFormField.validator أو يدوياً حسب الحاجة.
class Validators {
  Validators._();

  /// نص مطلوب (غير فارغ)
  static String? required(String? v, {String fieldName = 'الحقل'}) {
    final s = v?.trim();
    if (s == null || s.isEmpty) {
      return 'الرجاء تعبئة $fieldName';
    }
    return null;
  }

  /// طول أدنى
  static String? minLength(String? v, int min, {String fieldName = 'الحقل'}) {
    final s = v?.trim() ?? '';
    if (s.length < min) {
      return '$fieldName يجب أن لا يقل عن $min أحرف';
    }
    return null;
  }

  /// رقم هاتف يمني/عربي مبسّط:
  /// - يقبل 9 أرقام تبدأ بـ 7 (مثل 7XXXXXXXX) أو مع +967/00967 أو 0
  static String? phone(String? v, {String fieldName = 'رقم الهاتف'}) {
    final s = Formatters.normalizePhone(v ?? '');
    if (s.isEmpty) return 'الرجاء إدخال $fieldName';
    // بعد التطبيع نتوقع: 7XXXXXXXX (9 أرقام) أو 01XXXXXXXX (أرضي)، نسمح بـ 8-10 مبدئياً
    final digitsOnly = s.replaceAll(RegExp(r'\D'), '');
    if (!(digitsOnly.length >= 8 && digitsOnly.length <= 11)) {
      return '$fieldName غير صحيح';
    }
    return null;
  }

  /// رقم وطني/جواز (تحقق بسيط فقط)
  static String? nationalId(String? v, {String fieldName = 'الرقم'}) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return null; // ليس إلزامياً في كل النماذج
    final cleaned = s.replaceAll(RegExp(r'\s'), '');
    if (cleaned.length < 6 || cleaned.length > 20) {
      return '$fieldName غير صحيح';
    }
    return null;
  }

  /// إحداثيات: تقبل "lat,lon" (عشري) أو DMS مثل:
  /// 16°34'37.75" N 44°13'53.89" E
  static String? coords(String? v, {String fieldName = 'الإحداثيات'}) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return null; // ليست إلزامية في كل النماذج
    final pt = Formatters.tryParseGeo(s);
    if (pt == null) return '$fieldName غير صحيحة';
    if (pt.lat < -90 || pt.lat > 90 || pt.lon < -180 || pt.lon > 180) {
      return '$fieldName خارج النطاق المسموح';
    }
    return null;
  }

  /// قائمة غير فارغة
  static String? nonEmptyList<T>(List<T>? list,
      {String fieldName = 'الاختيار'}) {
    if (list == null || list.isEmpty) {
      return 'الرجاء اختيار $fieldName';
    }
    return null;
  }
}
