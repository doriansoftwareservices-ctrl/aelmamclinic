// lib/utils/pdf_text.dart
//
// أدوات لتشكيل النص العربي في تقارير PDF (حل مشكلة فقدان الحروف النهائية).

import 'package:arabic_reshaper/arabic_reshaper.dart';
import 'package:bidi/bidi.dart' as bidi;

final RegExp _rxArabic = RegExp(
  r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]',
);

String pdfText(String input) {
  if (input.isEmpty) return input;
  if (!_rxArabic.hasMatch(input)) return input;
  final reshaper = ArabicReshaper(ArabicReshaperConfig());
  final reshaped = reshaper.reshape(input);
  return String.fromCharCodes(bidi.logicalToVisual(reshaped));
}
