// lib/utils/pdf_text.dart
//
// أدوات لمعالجة اتجاه النص العربي في تقارير PDF بأقل اعتماد ممكن.
// نستخدم bidi فقط لتجنّب قيود نسخة Dart.

import 'package:aelmamclinic/utils/arabic_reshaper.dart';

final RegExp _rxArabic = RegExp(
  r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
);

String pdfText(String input) {
  if (input.isEmpty) return input;
  if (!_rxArabic.hasMatch(input)) return input;
  // إعادة تشكيل العربية فقط. عكس السلسلة كان يسبب كتابة الكلمات بالمقلوب.
  // نعتمد على textDirection في الـ PDF لتوليد اتجاه RTL الصحيح.
  final reshaped = ArabicReshaper.instance.reshape(input);
  return '\u200F$reshaped';
}

// ملاحظة: تم إلغاء عكس النص بالكامل لأنه كان ينتج كلمات عربية معكوسة.
