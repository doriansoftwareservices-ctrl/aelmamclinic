import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

class PdfFonts {
  final pw.Font regular;
  final pw.Font bold;

  const PdfFonts({required this.regular, required this.bold});
}

Future<PdfFonts> loadPdfFonts() async {
  try {
    final reg = await rootBundle.load('assets/fonts/Amiri-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/Amiri-Bold.ttf');
    return PdfFonts(
      regular: pw.Font.ttf(reg.buffer.asByteData()),
      bold: pw.Font.ttf(bold.buffer.asByteData()),
    );
  } catch (_) {
    try {
      final reg = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
      final bold = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
      return PdfFonts(
        regular: pw.Font.ttf(reg.buffer.asByteData()),
        bold: pw.Font.ttf(bold.buffer.asByteData()),
      );
    } catch (_) {
      return PdfFonts(
        regular: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
      );
    }
  }
}
