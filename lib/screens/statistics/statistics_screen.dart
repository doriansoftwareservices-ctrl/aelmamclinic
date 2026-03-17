// lib/screens/statistics/statistics_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:provider/provider.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/save_file_service.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/utils/pdf_fonts.dart';
import 'package:aelmamclinic/utils/report_localizer.dart';
import 'package:aelmamclinic/utils/pdf_text.dart';
import 'package:aelmamclinic/providers/statistics_provider.dart';
import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

/// نموذج بيانات بسيط للرسوم
class _ChartData {
  final String label;
  final double value;
  _ChartData(this.label, this.value);
}

String _displayChartLabel(String raw) => AppFormatters.localizeDateKey(raw);

double _safeTotal(Iterable<_ChartData> data) {
  return data.fold<double>(0, (sum, d) {
    final v = d.value;
    if (v.isNaN || v.isInfinite) return sum;
    return sum + v;
  });
}

double _safeNumber(double value) {
  if (value.isNaN || value.isInfinite) return 0;
  return value;
}

ZoomPanBehavior _defaultZoomPan() => ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableSelectionZooming: true,
      zoomMode: ZoomMode.x,
      maximumZoomLevel: 0.02,
    );

TrackballBehavior _defaultTrackball() => TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
    );

TooltipBehavior _defaultTooltip() => TooltipBehavior(
      enable: true,
      canShowMarker: true,
    );

/*──────────────────────── أدوات PDF ────────────────────────*/
class _PdfUtils {
  static ReportLocalizer _i18n() => ReportLocalizer();

  static Future<(pw.Font, pw.Font)> _loadFonts() async {
    final fonts = await loadPdfFonts();
    return (fonts.regular, fonts.bold);
  }

  static pw.PageTheme _pageTheme(pw.Font base, pw.Font bold) {
    return _i18n().pageTheme(
      base: base,
      bold: bold,
      margin: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 20),
    );
  }

  static String formatNumber(double value, {int decimals = 2}) {
    final i18n = _i18n();
    if (value.isNaN || value.isInfinite) {
      return i18n.formatNumber(0, decimalDigits: decimals);
    }
    return i18n.formatNumber(value, decimalDigits: decimals);
  }

  static String pdf(String raw) => _i18n().pdf(raw);

  static pw.Widget header(
    String title, {
    String? subtitle,
    pw.ImageProvider? logo,
    ClinicProfile? clinic,
  }) {
    final i18n = _i18n();
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        if (clinic != null)
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: _clinicInfoBlock(
                  title: _clinicNameEn(clinic),
                  address: _clinicAddressEn(clinic),
                  phoneLabel: 'Phone',
                  phoneValue: _clinicPhones(clinic),
                  align: pw.TextAlign.left,
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                ),
              ),
              pw.SizedBox(width: 12),
              _logoBox(logo),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: _clinicInfoBlock(
                  title: _clinicNameAr(clinic),
                  address: _clinicAddressAr(clinic),
                  phoneLabel: 'الهاتف',
                  phoneValue: _clinicPhones(clinic),
                  align: pw.TextAlign.right,
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                ),
              ),
            ],
          )
        else
          pw.Row(
            children: [
              _logoBox(logo),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: i18n.isRtl
                      ? pw.CrossAxisAlignment.end
                      : pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      i18n.pdf(i18n.isRtl ? 'إلمام كلينك' : 'Elmam Clinic'),
                      textAlign: i18n.startAlign,
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      i18n.pdf(title),
                      textAlign: i18n.startAlign,
                      style: const pw.TextStyle(fontSize: 12),
                    ),
                    if (subtitle != null)
                      pw.Text(
                        i18n.pdf(subtitle),
                        textAlign: i18n.startAlign,
                        style: pw.TextStyle(
                          fontSize: 10,
                          color: PdfColors.grey700,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        if (clinic != null)
          pw.Column(
            children: [
              pw.SizedBox(height: 6),
              pw.Text(
                i18n.pdf(title),
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 12,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (subtitle != null)
                pw.Text(
                  i18n.pdf(subtitle),
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey700,
                  ),
                ),
            ],
          ),
        pw.SizedBox(height: 8),
        pw.Divider(color: PdfColors.grey300, thickness: .8),
        pw.SizedBox(height: 8),
      ],
    );
  }

  static pw.Widget footer(
    pw.Context ctx,
    ClinicProfile? clinic,
  ) {
    final i18n = _i18n();
    final parts = <String>[
      if (clinic != null) i18n.clinicName(clinic),
      if (clinic != null) i18n.clinicAddress(clinic),
      if (clinic != null) i18n.withLabel('الهاتف', _clinicPhones(clinic)),
    ].where((part) => part.trim().isNotEmpty).toList();

    return pw.Container(
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(width: 0.6, color: PdfColors.grey300),
        ),
      ),
      child: pw.Row(
        children: [
          pw.Expanded(
            child: pw.Text(
              i18n.pdf(parts.join(' - ')),
              textAlign: i18n.startAlign,
              style: pw.TextStyle(
                fontSize: 9,
                color: PdfColors.blueGrey,
              ),
            ),
          ),
          pw.SizedBox(width: 8),
          pw.Text(
            i18n.pdf(i18n.pageLabel(ctx.pageNumber, ctx.pagesCount)),
            style: pw.TextStyle(
              fontSize: 9,
              color: PdfColors.blueGrey,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget simpleTable({
    required List<String> headers,
    required List<List<String>> rows,
  }) {
    final i18n = _i18n();
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.6),
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: headers
              .map(
                (h) => pw.Padding(
                  padding: const pw.EdgeInsets.all(8),
                  child: pw.Text(i18n.pdf(h),
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                ),
              )
              .toList(),
        ),
        ...rows.map(
          (r) => pw.TableRow(
            children: r
                .map(
                  (c) => pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    child: pw.Text(i18n.pdf(c),
                        textAlign: pw.TextAlign.center),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  // تقسيم القائمة chunks
  static Iterable<List<MapEntry<String, double>>> _chunk(
    List<MapEntry<String, double>> entries, {
    int size = 35,
  }) sync* {
    for (var i = 0; i < entries.length; i += size) {
      yield entries.sublist(i, math.min(i + size, entries.length));
    }
  }

  // تنظيف القيم لتفادي NaN/Infinity والسالب
  static Map<String, double> _sanitizeMap(Map<String, double> map) {
    final out = <String, double>{};
    map.forEach((k, v) {
      final d = v;
      if (d.isNaN || d.isInfinite) return;
      out[k] = d < 0 ? 0 : d;
    });
    if (out.isEmpty) out['—'] = 0;
    return out;
  }

  // محور X ثابت من labels (يضمن ≥ نقطتين لتفادي قسمة على صفر)
  static pw.GridAxis _xAxisFromLabels(List<String> labels) {
    final n = labels.length < 2 ? 2 : labels.length;
    return pw.FixedAxis(
      List<double>.generate(n, (i) => i.toDouble()),
      format: (v) {
        final i = v.round();
        return (i >= 0 && i < labels.length) ? labels[i] : '';
      },
      textStyle: pw.TextStyle(fontSize: 7),
      marginStart: 8,
      marginEnd: 8,
    );
  }

  static pw.GridAxis _yAxisAuto(double maxY) {
    final i18n = _i18n();
    final m = (maxY <= 0 || maxY.isNaN || maxY.isInfinite) ? 1 : maxY;
    final top = (m * 1.2);
    return pw.FixedAxis(
      List<double>.generate(6, (i) => top * i / 5.0),
      format: (v) => i18n.formatNumber(v, decimalDigits: 0),
      textStyle: const pw.TextStyle(fontSize: 7),
      marginStart: 8,
      marginEnd: 8,
    );
  }

  // مخططات Line متعددة (تقسيم تلقائي إذا البيانات طويلة)
  static List<pw.Widget> lineChartsFromMap(
    Map<String, double> rawMap, {
    String? title,
    int chunkSize = 35,
    double height = 260,
  }) {
    final i18n = _i18n();
    final map = _sanitizeMap(rawMap);
    final entries = map.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final widgets = <pw.Widget>[];

    for (final part in _chunk(entries, size: chunkSize)) {
      var labels = part.map((e) => i18n.pdf(AppFormatters.localizeDateKey(
        e.key,
        languageCode: i18n.languageCode,
      ))).toList();
      var values = part.map((e) => e.value).toList();

      // إن كان لدينا نقطة واحدة فقط، نضيف نقطة وهمية لتفادي مشاكل step=0
      if (values.length == 1) {
        labels = List.of(labels)..add('');
        values = List.of(values)..add(0);
      }

      final maxY = values.fold<double>(0, math.max);

      widgets.addAll([
        if (title != null && entries.length <= chunkSize)
          pw.Text(i18n.pdf(title),
              style:
                  pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
        pw.Container(
          height: height,
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Chart(
            grid: pw.CartesianGrid(
              xAxis: _xAxisFromLabels(labels),
              yAxis: _yAxisAuto(maxY),
            ),
            datasets: [
              pw.LineDataSet(
                isCurved: true,
                drawSurface: true,
                data: List<pw.PointChartValue>.generate(
                  values.length,
                  (i) => pw.PointChartValue(i.toDouble(), values[i]),
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 12),
      ]);
    }
    return widgets;
  }

  // مخططات Bar عمودية (تقسيم تلقائي)
  static List<pw.Widget> barChartsFromMap(
    Map<String, double> rawMap, {
    String? title,
    int chunkSize = 25,
    double height = 280,
  }) {
    final i18n = _i18n();
    final map = _sanitizeMap(rawMap);
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final widgets = <pw.Widget>[];

    for (final part in _chunk(entries, size: chunkSize)) {
      var labels = part.map((e) => i18n.pdf(AppFormatters.localizeDateKey(
        e.key,
        languageCode: i18n.languageCode,
      ))).toList();
      var values = part.map((e) => e.value).toList();

      // إن كان لدينا عمود واحد فقط، نضيف عمودًا صفرّيًا (label فارغ) لضمان ≥2
      if (values.length == 1) {
        labels = List.of(labels)..add('');
        values = List.of(values)..add(0);
      }

      final maxY = values.fold<double>(0, math.max);

      widgets.addAll([
        if (title != null && entries.length <= chunkSize)
          pw.Text(i18n.pdf(title),
              style:
                  pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
        pw.Container(
          height: height,
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Chart(
            grid: pw.CartesianGrid(
              xAxis: _xAxisFromLabels(labels),
              yAxis: _yAxisAuto(maxY),
            ),
            datasets: [
              pw.BarDataSet(
                width: values.length == 1 ? 0.5 : 0.9,
                borderColor: PdfColors.grey600,
                data: List<pw.PointChartValue>.generate(
                  values.length,
                  (i) => pw.PointChartValue(i.toDouble(), values[i]),
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 12),
      ]);
    }
    return widgets;
  }

  /// مشاركة
  static Future<void> shareDoc(pw.Document doc, String rawStem) async {
    final i18n = _i18n();
    final dir = await getTemporaryDirectory();
    final fileName = i18n.fileName(
      rawStem,
      extension: 'pdf',
      suffixes: [DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())],
    );
    final path = '${dir.path}/$fileName';
    final file = File(path);
    await file.writeAsBytes(await doc.save());
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        text: i18n.tr(rawStem),
      ),
    );
  }

  /// تنزيل
  static Future<void> downloadDoc(
      BuildContext context, pw.Document doc, String rawStem) async {
    final i18n = _i18n();
    final bytes = await doc.save();
    final fileName = i18n.fileName(
      rawStem,
      extension: 'pdf',
      suffixes: [DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())],
    );
    await saveFileBytes(bytes, fileName);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LocalizedText('تم حفظ الملف بنجاح.')),
    );
  }

  static String _clinicPhones(ClinicProfile clinic) {
    final map = clinic.toMap();
    final p1 = (map['phone'] ?? '').toString().trim();
    final p2 = (map['phone2'] ?? '').toString().trim();
    return p2.isEmpty ? p1 : '$p1 / $p2';
  }

  static String _resolveBilingualText(String primary, String fallback) {
    final p = primary.trim();
    if (p.isNotEmpty) return p;
    final f = fallback.trim();
    return f.isNotEmpty ? f : '—';
  }

  static String _clinicNameAr(ClinicProfile clinic) {
    return _resolveBilingualText(clinic.nameAr, clinic.nameEn);
  }

  static String _clinicNameEn(ClinicProfile clinic) {
    return _resolveBilingualText(clinic.nameEn, clinic.nameAr);
  }

  static String _clinicAddressAr(ClinicProfile clinic) {
    return _resolveBilingualText(clinic.addressAr, clinic.addressEn);
  }

  static String _clinicAddressEn(ClinicProfile clinic) {
    return _resolveBilingualText(clinic.addressEn, clinic.addressAr);
  }

  static pw.Widget _clinicInfoBlock({
    required String title,
    required String address,
    required String phoneLabel,
    required String phoneValue,
    required pw.TextAlign align,
    required pw.CrossAxisAlignment crossAxisAlignment,
  }) {
    final renderedPhone = phoneValue.trim();
    final phoneLine = renderedPhone.isEmpty ? phoneLabel : '$phoneLabel: $renderedPhone';
    return pw.Column(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        pw.Text(
          pdfText(title.trim().isEmpty ? '—' : title),
          textAlign: align,
          style: pw.TextStyle(
            fontSize: 12.5,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.blueGrey,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          pdfText(address.trim().isEmpty ? '—' : address),
          textAlign: align,
          style: pw.TextStyle(
            fontSize: 8.8,
            color: PdfColors.grey700,
            height: 1.25,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          pdfText(phoneLine),
          textAlign: align,
          style: pw.TextStyle(
            fontSize: 8.8,
            color: PdfColors.grey700,
            height: 1.25,
          ),
        ),
      ],
    );
  }


  static pw.Widget _logoBox(pw.ImageProvider? logo) {
    return pw.Container(
      width: 48,
      height: 48,
      decoration: pw.BoxDecoration(
        borderRadius: pw.BorderRadius.circular(12),
        color: PdfColor.fromHex('#E8F1FB'),
      ),
      child: logo == null
          ? pw.Center(
              child: pw.Text(
                'A',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
            )
          : pw.Padding(
              padding: const pw.EdgeInsets.all(6),
              child: pw.Image(logo, fit: pw.BoxFit.contain),
            ),
    );
  }
}

/*──────────────────────── شريط تحكم أعلى كل قسم ────────────────────────*/
class _FilterAndExportBar extends StatelessWidget {
  final String title;
  final DateTime? start;
  final DateTime? end;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;
  final VoidCallback? onReset;
  final VoidCallback onExportPdf;
  final VoidCallback onDownloadPdf;

  const _FilterAndExportBar({
    required this.title,
    required this.start,
    required this.end,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onExportPdf,
    required this.onDownloadPdf,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final df = AppFormatters.dateFormat('yyyy-MM-dd');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        children: [
          NeuCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: kPrimaryColor.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: const Icon(Icons.bar_chart_rounded,
                      color: kPrimaryColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LocalizedText(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.start,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // صف التحكم
          Row(
            children: [
              Expanded(
                child: TDateButton(
                  icon: Icons.calendar_month_rounded,
                  label: start == null ? 'من تاريخ' : df.format(start!),
                  onTap: onPickStart,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TDateButton(
                  icon: Icons.event_rounded,
                  label: end == null ? 'إلى تاريخ' : df.format(end!),
                  onTap: onPickEnd,
                ),
              ),
              const SizedBox(width: 10),
              TOutlinedButton(
                icon: Icons.picture_as_pdf,
                label: 'تصدير',
                onPressed: onExportPdf,
              ),
              const SizedBox(width: 8),
              TOutlinedButton(
                icon: Icons.download_rounded,
                label: 'تنزيل',
                onPressed: onDownloadPdf,
              ),
              const SizedBox(width: 8),
              TOutlinedButton(
                icon: Icons.refresh_rounded,
                label: 'مسح',
                onPressed: onReset,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/*──────────────────────── شاشة الرسوم البيانية الرئيسية ────────────────────────*/
class StatisticsScreen extends StatelessWidget {
  const StatisticsScreen({super.key});

  StatisticsProvider? _tryRead(BuildContext context) {
    try {
      return Provider.of<StatisticsProvider>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = _tryRead(context);
    if (existing != null) {
      return const _StatisticsScreenBody();
    }
    return ChangeNotifierProvider(
      create: (_) => StatisticsProvider(),
      child: const _StatisticsScreenBody(),
    );
  }
}

class _StatisticsScreenBody extends StatefulWidget {
  const _StatisticsScreenBody();

  @override
  State<_StatisticsScreenBody> createState() => _StatisticsScreenBodyState();
}

class _StatisticsScreenBodyState extends State<_StatisticsScreenBody> {
  StatisticsProvider? _stats;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stats ??= (() {
      try {
        return Provider.of<StatisticsProvider>(context, listen: false);
      } catch (_) {
        return null;
      }
    })();
    _stats?.setChartsActive(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _stats?.refreshCharts();
    });
  }

  @override
  void dispose() {
    _stats?.setChartsActive(false);
    super.dispose();
  }

  Future<void> _pickStart() async {
    final stats = context.read<StatisticsProvider>();
    final d = await showDatePicker(
      context: context,
      initialDate: stats.chartsFrom ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      stats.setChartsRange(from: d, to: stats.chartsTo);
    }
  }

  Future<void> _pickEnd() async {
    final stats = context.read<StatisticsProvider>();
    final d = await showDatePicker(
      context: context,
      initialDate: stats.chartsTo ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      stats.setChartsRange(from: stats.chartsFrom, to: d);
    }
  }

  Future<void> _pickAsOf() async {
    final stats = context.read<StatisticsProvider>();
    final picked = await showDatePicker(
      context: context,
      initialDate: stats.doctorOutstandingAsOf,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (picked != null) {
      if (!mounted) return;
      stats.setDoctorOutstandingAsOf(
        DateTime(picked.year, picked.month, picked.day, 23, 59, 59),
      );
    }
  }

  void _resetRange() {
    final stats = context.read<StatisticsProvider>();
    stats.setChartsRange(from: null, to: null);
  }

  List<_ChartData> _mapToData(Map<String, double> map) {
    return map.entries
        .map((e) => _ChartData(_displayChartLabel(e.key), e.value))
        .toList()
      ..sort((a, b) => a.label.compareTo(b.label));
  }

  List<_ChartData> _mapToDataInt(Map<String, int> map) {
    return map.entries
        .map((e) => _ChartData(_displayChartLabel(e.key), e.value.toDouble()))
        .toList()
      ..sort((a, b) => a.label.compareTo(b.label));
  }

  List<MapEntry<String, double>> _topEntries(
    Map<String, double> map, {
    int limit = 5,
  }) {
    final entries = map.entries
        .map((e) => MapEntry(e.key, _safeNumber(e.value)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.length <= limit) return entries;
    return entries.take(limit).toList();
  }

  double _totalMap(Map<String, double> map) =>
      _safeTotal(_mapToData(map));

  Future<pw.Document> _buildMapPdf({
    required String title,
    required Map<String, double> map,
    required List<String> headers,
    required String chartKind, // line | bar
    DateTime? from,
    DateTime? to,
  }) async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final rows = map.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final tableRows =
        rows.map((e) => [e.key, _PdfUtils.formatNumber(e.value)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header(
            title,
            subtitle: _subtitleRange(from, to),
            logo: logo,
            clinic: clinic,
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            _PdfUtils.pdf('الإجمالي: ${_PdfUtils.formatNumber(_totalMap(map))}'),
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 10),
          if (chartKind == 'bar')
            ..._PdfUtils.barChartsFromMap(map)
          else
            ..._PdfUtils.lineChartsFromMap(map),
          _PdfUtils.simpleTable(headers: headers, rows: tableRows),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportMapPdf({
    required String title,
    required String prefix,
    required Map<String, double> map,
    required List<String> headers,
    required String chartKind,
    DateTime? from,
    DateTime? to,
  }) async {
    final doc = await _buildMapPdf(
      title: title,
      map: map,
      headers: headers,
      chartKind: chartKind,
      from: from,
      to: to,
    );
    await _PdfUtils.shareDoc(doc, title);
  }

  Future<void> _downloadMapPdf({
    required String title,
    required String prefix,
    required Map<String, double> map,
    required List<String> headers,
    required String chartKind,
    DateTime? from,
    DateTime? to,
  }) async {
    final doc = await _buildMapPdf(
      title: title,
      map: map,
      headers: headers,
      chartKind: chartKind,
      from: from,
      to: to,
    );
    await _PdfUtils.downloadDoc(context, doc, title);
  }

  Future<pw.Document> _buildOutstandingPdf(
    List<Map<String, dynamic>> rows,
    DateTime asOf,
  ) async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final fmt = AppFormatters.dateFormat('yyyy-MM-dd');
    final tableRows = rows.map((r) {
      final start = DateTime.tryParse('${r['periodStart'] ?? ''}');
      final end = DateTime.tryParse('${r['periodEnd'] ?? ''}');
      final period =
          '${start != null ? fmt.format(start) : '—'} → ${end != null ? fmt.format(end) : '—'}';
      return [
        r['doctorName']?.toString() ?? '—',
        period,
        _PdfUtils.formatNumber((r['ratioSum'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber((r['directInput'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber((r['totalLoans'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber((r['totalDiscounts'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber((r['totalPaid'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber((r['netPay'] as num?)?.toDouble() ?? 0.0),
      ];
    }).toList();

    final totalNet = rows.fold<double>(
      0.0,
      (sum, r) => sum + _safeNumber((r['netPay'] as num?)?.toDouble() ?? 0.0),
    );

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header(
            'تقرير مستحقات الأطباء',
            subtitle: 'حتى تاريخ: ${fmt.format(asOf)}',
            logo: logo,
            clinic: clinic,
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            _PdfUtils.pdf('الإجمالي: ${_PdfUtils.formatNumber(totalNet)}'),
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 10),
          _PdfUtils.simpleTable(
            headers: [
              'الطبيب',
              'الفترة',
              'النِّسب',
              'المدخلات',
              'السلف',
              'الخصومات',
              'المدفوع',
              'الصافي',
            ],
            rows: tableRows,
          ),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportOutstanding(
    List<Map<String, dynamic>> rows,
    DateTime asOf,
  ) async {
    final doc = await _buildOutstandingPdf(rows, asOf);
    await _PdfUtils.shareDoc(doc, 'تقرير مستحقات الأطباء');
  }

  Future<void> _downloadOutstanding(
    List<Map<String, dynamic>> rows,
    DateTime asOf,
  ) async {
    final doc = await _buildOutstandingPdf(rows, asOf);
    await _PdfUtils.downloadDoc(context, doc, 'تقرير مستحقات الأطباء');
  }

  @override
  Widget build(BuildContext context) {
    final stats = context.watch<StatisticsProvider>();
    final scheme = Theme.of(context).colorScheme;
    final isSuperAdmin = context.watch<AuthProvider>().isSuperAdmin;
    final incomeData = _mapToData(stats.incomeByDate);
    final consumptionData = _mapToData(stats.consumptionByDate);
    final incomeByDoctor = _mapToData(stats.incomeByDoctor);
    final consumptionByType = _mapToData(stats.consumptionByType);
    final doctorShareByDate = _mapToData(stats.doctorShareByDate);
    final netProfitByDate = _mapToData(stats.netProfitByDate);
    final supportStarsData = _mapToDataInt(stats.supportStarsCount);

    return Scaffold(
      appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/logo2.png',
                height: 24,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
              const LocalizedText('الرسوم البيانية'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: context.trRaw('تحديث'),
              onPressed: stats.chartsBusy ? null : stats.refreshCharts,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: LinearGradient(
                    colors: [
                      scheme.primary.withValues(alpha: 0.12),
                      scheme.secondary.withValues(alpha: 0.08),
                    ],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_graph_rounded,
                            color: kPrimaryColor),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: LocalizedText('لوحة التحليل المتقدم',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _resetRange,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const LocalizedText('الكل'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TOutlinedButton(
                            icon: Icons.date_range,
                            label: stats.chartsFrom == null
                                ? 'من...'
                                : DateFormat('yyyy-MM-dd')
                                    .format(stats.chartsFrom!),
                            onPressed: _pickStart,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TOutlinedButton(
                            icon: Icons.date_range,
                            label: stats.chartsTo == null
                                ? 'إلى...'
                                : DateFormat('yyyy-MM-dd')
                                    .format(stats.chartsTo!),
                            onPressed: _pickEnd,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverToBoxAdapter(
                child: _SummaryGrid(stats: stats),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverToBoxAdapter(
                child: _GrowthAnalysisPanel(stats: stats),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverToBoxAdapter(
                child: _ChartsSection(
                  title: 'مقارنة شهرية',
                  totalLabel: 'آخر 6 أشهر',
                  onExport: () => _exportMapPdf(
                    title: 'تقرير المقارنة الشهرية (الدخل)',
                    prefix: 'monthly_income_comparison',
                    map: stats.monthlyIncome,
                    headers: const ['الشهر', 'الدخل'],
                    chartKind: 'bar',
                  ),
                  onDownload: () => _downloadMapPdf(
                    title: 'تقرير المقارنة الشهرية (الدخل)',
                    prefix: 'monthly_income_comparison',
                    map: stats.monthlyIncome,
                    headers: const ['الشهر', 'الدخل'],
                    chartKind: 'bar',
                  ),
                  child: _MultiBarChart(
                    categories: (stats.monthlyIncome.keys.toList()
                      ..sort((a, b) => a.compareTo(b))),
                    series: [
                      _SeriesSpec(
                        name: 'الدخل',
                        color: scheme.primary,
                        data: stats.monthlyIncome,
                      ),
                      _SeriesSpec(
                        name: 'الاستهلاك',
                        color: scheme.secondary,
                        data: stats.monthlyConsumption,
                      ),
                      _SeriesSpec(
                        name: 'صافي الربح',
                        color: scheme.tertiary,
                        data: stats.monthlyNetProfitSeries,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverToBoxAdapter(
                child: _ChartsSection(
                  title: 'مقارنة سنوية (${stats.compareYearA} مقابل ${stats.compareYearB})',
                  totalLabel: 'ملخص الأشهر من 01 إلى 12',
                  onExport: () => _exportMapPdf(
                    title:
                        'تقرير مقارنة سنوية الدخل (${stats.compareYearA} vs ${stats.compareYearB})',
                    prefix: 'year_income_compare',
                    map: stats.yearIncomeB,
                    headers: const ['الشهر', 'الدخل'],
                    chartKind: 'bar',
                  ),
                  onDownload: () => _downloadMapPdf(
                    title:
                        'تقرير مقارنة سنوية الدخل (${stats.compareYearA} vs ${stats.compareYearB})',
                    prefix: 'year_income_compare',
                    map: stats.yearIncomeB,
                    headers: const ['الشهر', 'الدخل'],
                    chartKind: 'bar',
                  ),
                  child: Column(
                    children: [
                      _MultiBarChart(
                        categories: (stats.yearIncomeA.keys.toList()
                          ..sort((a, b) => a.compareTo(b))),
                        series: [
                          _SeriesSpec(
                            name: '${stats.compareYearA} دخل',
                            color: scheme.secondary,
                            data: stats.yearIncomeA,
                          ),
                          _SeriesSpec(
                            name: '${stats.compareYearB} دخل',
                            color: scheme.primary,
                            data: stats.yearIncomeB,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _MultiBarChart(
                        categories: (stats.yearNetA.keys.toList()
                          ..sort((a, b) => a.compareTo(b))),
                        series: [
                          _SeriesSpec(
                            name: '${stats.compareYearA} صافي',
                            color: scheme.tertiary,
                            data: stats.yearNetA,
                          ),
                          _SeriesSpec(
                            name: '${stats.compareYearB} صافي',
                            color: scheme.primary,
                            data: stats.yearNetB,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverToBoxAdapter(
                child: _ChartsSection(
                  title: 'توقعات الاتجاه (3 أشهر القادمة)',
                  totalLabel: 'توقعات مبنية على آخر 6 أشهر',
                  onExport: () => _exportMapPdf(
                    title: 'توقعات الدخل للأشهر القادمة',
                    prefix: 'forecast_income',
                    map: stats.incomeForecast,
                    headers: const ['الشهر', 'القيمة'],
                    chartKind: 'line',
                  ),
                  onDownload: () => _downloadMapPdf(
                    title: 'توقعات الدخل للأشهر القادمة',
                    prefix: 'forecast_income',
                    map: stats.incomeForecast,
                    headers: const ['الشهر', 'القيمة'],
                    chartKind: 'line',
                  ),
                  child: Column(
                    children: [
                      _ForecastChart(
                        title: 'الدخل المتوقع',
                        actual: stats.monthlyIncome,
                        forecast: stats.incomeForecast,
                        actualColor: scheme.primary,
                        forecastColor: scheme.secondary,
                      ),
                      const SizedBox(height: 12),
                      _ForecastChart(
                        title: 'صافي الربح المتوقع',
                        actual: stats.monthlyNetProfitSeries,
                        forecast: stats.netForecast,
                        actualColor: scheme.tertiary,
                        forecastColor: scheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverList(
                delegate: SliverChildListDelegate(
                  [
                    _ChartsSection(
                      title: 'الدخل بالتاريخ',
                      totalLabel:
                          'الإجمالي: ${_PdfUtils.formatNumber(_totalMap(stats.incomeByDate))}',
                      onExport: () => _exportMapPdf(
                        title: 'تقرير الدخل بالتاريخ',
                        prefix: 'income_by_date',
                        map: stats.incomeByDate,
                        headers: const ['التاريخ', 'الدخل'],
                        chartKind: 'line',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      onDownload: () => _downloadMapPdf(
                        title: 'تقرير الدخل بالتاريخ',
                        prefix: 'income_by_date',
                        map: stats.incomeByDate,
                        headers: const ['التاريخ', 'الدخل'],
                        chartKind: 'line',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      child: Column(
                        children: [
                          _LineAndPieCharts(
                            data: incomeData,
                            primaryTitle: 'الدخل بالتاريخ',
                            accent: scheme.primary,
                          ),
                          const SizedBox(height: 12),
                          _TopList(
                            title: 'أعلى الأيام دخلاً',
                            entries: _topEntries(stats.incomeByDate),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _ChartsSection(
                      title: 'الاستهلاك بالتاريخ',
                      totalLabel:
                          'الإجمالي: ${_PdfUtils.formatNumber(_totalMap(stats.consumptionByDate))}',
                      onExport: () => _exportMapPdf(
                        title: 'تقرير الاستهلاك بالتاريخ',
                        prefix: 'consumption_by_date',
                        map: stats.consumptionByDate,
                        headers: const ['التاريخ', 'الاستهلاك'],
                        chartKind: 'line',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      onDownload: () => _downloadMapPdf(
                        title: 'تقرير الاستهلاك بالتاريخ',
                        prefix: 'consumption_by_date',
                        map: stats.consumptionByDate,
                        headers: const ['التاريخ', 'الاستهلاك'],
                        chartKind: 'line',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      child: Column(
                        children: [
                          _LineAndPieCharts(
                            data: consumptionData,
                            primaryTitle: 'الاستهلاك بالتاريخ',
                            accent: scheme.secondary,
                          ),
                          const SizedBox(height: 12),
                          _TopList(
                            title: 'أعلى أيام الاستهلاك',
                            entries: _topEntries(stats.consumptionByDate),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _ChartsSection(
                      title: 'الدخل حسب الطبيب',
                      totalLabel:
                          'الإجمالي: ${_PdfUtils.formatNumber(_totalMap(stats.incomeByDoctor))}',
                      onExport: () => _exportMapPdf(
                        title: 'تقرير الدخل حسب الطبيب',
                        prefix: 'income_by_doctor',
                        map: stats.incomeByDoctor,
                        headers: const ['الطبيب', 'الدخل'],
                        chartKind: 'bar',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      onDownload: () => _downloadMapPdf(
                        title: 'تقرير الدخل حسب الطبيب',
                        prefix: 'income_by_doctor',
                        map: stats.incomeByDoctor,
                        headers: const ['الطبيب', 'الدخل'],
                        chartKind: 'bar',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      child: Column(
                        children: [
                          _BarChart(
                            data: incomeByDoctor,
                            title: 'الدخل حسب الطبيب',
                            accent: scheme.primary,
                          ),
                          const SizedBox(height: 12),
                          _TopList(
                            title: 'الأطباء الأعلى دخلاً',
                            entries: _topEntries(stats.incomeByDoctor),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _ChartsSection(
                      title: 'نوعية الاستهلاك',
                      totalLabel:
                          'الإجمالي: ${_PdfUtils.formatNumber(_totalMap(stats.consumptionByType))}',
                      onExport: () => _exportMapPdf(
                        title: 'تقرير نوعية الاستهلاك',
                        prefix: 'consumption_by_type',
                        map: stats.consumptionByType,
                        headers: const ['النوع', 'القيمة'],
                        chartKind: 'bar',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      onDownload: () => _downloadMapPdf(
                        title: 'تقرير نوعية الاستهلاك',
                        prefix: 'consumption_by_type',
                        map: stats.consumptionByType,
                        headers: const ['النوع', 'القيمة'],
                        chartKind: 'bar',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      child: Column(
                        children: [
                          _BarChart(
                            data: consumptionByType,
                            title: 'نوعية الاستهلاك',
                            accent: scheme.tertiary,
                          ),
                          const SizedBox(height: 12),
                          _TopList(
                            title: 'الأصناف الأعلى استهلاكاً',
                            entries: _topEntries(stats.consumptionByType),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _ChartsSection(
                      title: 'حصة الأطباء بالتاريخ',
                      totalLabel:
                          'الإجمالي: ${_PdfUtils.formatNumber(_totalMap(stats.doctorShareByDate))}',
                      onExport: () => _exportMapPdf(
                        title: 'تقرير حصة الأطباء بالتاريخ',
                        prefix: 'doctor_share_by_date',
                        map: stats.doctorShareByDate,
                        headers: const ['التاريخ', 'الحصة'],
                        chartKind: 'line',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      onDownload: () => _downloadMapPdf(
                        title: 'تقرير حصة الأطباء بالتاريخ',
                        prefix: 'doctor_share_by_date',
                        map: stats.doctorShareByDate,
                        headers: const ['التاريخ', 'الحصة'],
                        chartKind: 'line',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      child: _LineAndPieCharts(
                        data: doctorShareByDate,
                        primaryTitle: 'حصة الأطباء بالتاريخ',
                        accent: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _ChartsSection(
                      title: 'مستحقات الأطباء',
                      totalLabel:
                          'حتى تاريخ: ${DateFormat('yyyy-MM-dd').format(stats.doctorOutstandingAsOf)}',
                      leadingAction: TextButton.icon(
                        onPressed: _pickAsOf,
                        icon: const Icon(Icons.event),
                        label: const LocalizedText('تاريخ'),
                      ),
                      onExport: () => _exportOutstanding(
                        stats.doctorOutstandingRows,
                        stats.doctorOutstandingAsOf,
                      ),
                      onDownload: () => _downloadOutstanding(
                        stats.doctorOutstandingRows,
                        stats.doctorOutstandingAsOf,
                      ),
                      child: _OutstandingTable(rows: stats.doctorOutstandingRows),
                    ),
                    const SizedBox(height: 16),
                    _ChartsSection(
                      title: 'صافي الأرباح بالتاريخ',
                      totalLabel:
                          'الإجمالي: ${_PdfUtils.formatNumber(_totalMap(stats.netProfitByDate))}',
                      onExport: () => _exportMapPdf(
                        title: 'تقرير صافي الأرباح بالتاريخ',
                        prefix: 'net_profit_by_date',
                        map: stats.netProfitByDate,
                        headers: const ['التاريخ', 'الصافي'],
                        chartKind: 'line',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      onDownload: () => _downloadMapPdf(
                        title: 'تقرير صافي الأرباح بالتاريخ',
                        prefix: 'net_profit_by_date',
                        map: stats.netProfitByDate,
                        headers: const ['التاريخ', 'الصافي'],
                        chartKind: 'line',
                        from: stats.chartsFrom,
                        to: stats.chartsTo,
                      ),
                      child: _LineAndPieCharts(
                        data: netProfitByDate,
                        primaryTitle: 'صافي الأرباح بالتاريخ',
                        accent: scheme.secondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (isSuperAdmin) ...[
                      _ChartsSection(
                        title: 'تقييم خدمة العملاء',
                        totalLabel:
                            'المتوسط: ${stats.supportRatingAvg.toStringAsFixed(2)} | الإجمالي: ${stats.supportRatingsCount}',
                        onExport: () => _exportMapPdf(
                          title: 'تقرير تقييمات خدمة العملاء (متوسط شهري)',
                          prefix: 'support_ratings_monthly_avg',
                          map: stats.supportMonthlyAvg,
                          headers: const ['الشهر', 'المتوسط'],
                          chartKind: 'bar',
                          from: stats.chartsFrom,
                          to: stats.chartsTo,
                        ),
                        onDownload: () => _downloadMapPdf(
                          title: 'تقرير تقييمات خدمة العملاء (متوسط شهري)',
                          prefix: 'support_ratings_monthly_avg',
                          map: stats.supportMonthlyAvg,
                          headers: const ['الشهر', 'المتوسط'],
                          chartKind: 'bar',
                          from: stats.chartsFrom,
                          to: stats.chartsTo,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                _KpiCard(
                                  item: _KpiItem(
                                    title: 'متوسط التقييم',
                                    value: stats.supportRatingAvg
                                        .toStringAsFixed(2),
                                    icon: Icons.star_rounded,
                                    color: scheme.primary,
                                  ),
                                ),
                                _KpiCard(
                                  item: _KpiItem(
                                    title: 'عدد التقييمات',
                                    value:
                                        stats.supportRatingsCount.toString(),
                                    icon: Icons.rate_review_rounded,
                                    color: scheme.secondary,
                                  ),
                                ),
                                _KpiCard(
                                  item: _KpiItem(
                                    title: 'نسبة الرضا (4-5)',
                                    value:
                                        '${stats.supportSatisfactionPct.toStringAsFixed(1)}%',
                                    icon: Icons.sentiment_satisfied_alt_rounded,
                                    color: scheme.tertiary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _BarChart(
                              data: _mapToData(stats.supportMonthlyAvg),
                              title: 'متوسط التقييم شهرياً',
                              accent: scheme.primary,
                            ),
                            const SizedBox(height: 12),
                            _BarChart(
                              data: _mapToDataInt(stats.supportMonthlyCount),
                              title: 'عدد التقييمات شهرياً',
                              accent: scheme.secondary,
                            ),
                            const SizedBox(height: 12),
                            _BarChart(
                              data: supportStarsData,
                              title: 'توزيع النجوم (1-5)',
                              accent: scheme.tertiary,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
    );
  }
}

class _ChartsSection extends StatelessWidget {
  final String title;
  final String totalLabel;
  final Widget child;
  final VoidCallback onExport;
  final VoidCallback onDownload;
  final Widget? leadingAction;

  const _ChartsSection({
    required this.title,
    required this.totalLabel,
    required this.child,
    required this.onExport,
    required this.onDownload,
    this.leadingAction,
  });

  @override
  Widget build(BuildContext context) {
    return NeuCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: LocalizedText(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              if (leadingAction != null) leadingAction!,
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (v) {
                  if (v == 'export') onExport();
                  if (v == 'download') onDownload();
                },
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: 'export',
                    child: LocalizedText('مشاركة PDF'),
                  ),
                  PopupMenuItem(
                    value: 'download',
                    child: LocalizedText('تنزيل PDF'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          LocalizedText(
            totalLabel,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  final StatisticsProvider stats;

  const _SummaryGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final items = [
      _KpiItem(
        title: 'إيرادات الشهر',
        value: stats.fmtRevenue,
        icon: Icons.trending_up_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      _KpiItem(
        title: 'مصاريف الشهر',
        value: stats.fmtExpense,
        icon: Icons.payments_rounded,
        color: Theme.of(context).colorScheme.secondary,
      ),
      _KpiItem(
        title: 'صافي الربح',
        value: stats.fmtNetProfit,
        icon: Icons.savings_rounded,
        color: Theme.of(context).colorScheme.tertiary,
      ),
      _KpiItem(
        title: 'حصة الأطباء',
        value: stats.fmtDoctorRatios,
        icon: Icons.medical_services_rounded,
        color: const Color(0xFF3A7FF6),
      ),
      _KpiItem(
        title: 'مدخلات الأطباء',
        value: stats.fmtDoctorInputs,
        icon: Icons.stacked_line_chart_rounded,
        color: const Color(0xFF0FA3B1),
      ),
      _KpiItem(
        title: 'مستحقات المرضى',
        value: stats.fmtPatientsRemaining,
        icon: Icons.account_balance_wallet_rounded,
        color: const Color(0xFF2E8B57),
      ),
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: items.map((item) => _KpiCard(item: item)).toList(),
    );
  }
}

class _GrowthAnalysisPanel extends StatelessWidget {
  final StatisticsProvider stats;

  const _GrowthAnalysisPanel({required this.stats});

  @override
  Widget build(BuildContext context) {
    return NeuCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LocalizedText('تحليل النمو والانخفاض (مقارنة بالفترة السابقة)',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _GrowthCard(
                title: 'الدخل',
                pct: stats.incomeGrowthPct,
                trend: stats.incomeTrend,
                color: Theme.of(context).colorScheme.primary,
              ),
              _GrowthCard(
                title: 'الاستهلاك',
                pct: stats.consumptionGrowthPct,
                trend: stats.consumptionTrend,
                color: Theme.of(context).colorScheme.secondary,
              ),
              _GrowthCard(
                title: 'صافي الربح',
                pct: stats.netGrowthPct,
                trend: stats.netTrend,
                color: Theme.of(context).colorScheme.tertiary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GrowthCard extends StatelessWidget {
  final String title;
  final double pct;
  final String trend;
  final Color color;

  const _GrowthCard({
    required this.title,
    required this.pct,
    required this.trend,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isUp = pct > 0.5;
    final isDown = pct < -0.5;
    final icon = isUp
        ? Icons.trending_up_rounded
        : (isDown ? Icons.trending_down_rounded : Icons.trending_flat_rounded);
    final pctText = '${pct.toStringAsFixed(1)}%';
    return SizedBox(
      width: 220,
      child: NeuCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LocalizedText(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LocalizedText(
              pctText,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            LocalizedText('الاتجاه: $trend',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeriesSpec {
  final String name;
  final Color color;
  final Map<String, double> data;

  _SeriesSpec({
    required this.name,
    required this.color,
    required this.data,
  });
}

class _MultiBarChart extends StatelessWidget {
  final List<String> categories;
  final List<_SeriesSpec> series;

  const _MultiBarChart({
    required this.categories,
    required this.series,
  });

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) {
      return _EmptyChart(
        message: context.trRaw('لا توجد بيانات كافية للمقارنة الشهرية'),
      );
    }

    final chartWidth = math.max(320.0, 90.0 * categories.length);
    final tooltip = _defaultTooltip();
    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: chartWidth,
        height: 320,
        child: SfCartesianChart(
          title: ChartTitle(text: context.trRaw('مقارنة شهرية')),
          enableAxisAnimation: false,
          plotAreaBorderWidth: 0,
          legend: Legend(isVisible: true, position: LegendPosition.bottom),
          primaryXAxis: CategoryAxis(labelRotation: 45),
          primaryYAxis: NumericAxis(),
          tooltipBehavior: tooltip,
          zoomPanBehavior: zoomPan,
          trackballBehavior: trackball,
          series: series.map((s) {
            return ColumnSeries<_ChartData, String>(
              name: context.trRaw(s.name),
              color: s.color,
              dataSource: categories
                  .map((c) => _ChartData(_displayChartLabel(c), s.data[c] ?? 0))
                  .toList(),
              xValueMapper: (d, _) => d.label,
              yValueMapper: (d, _) => d.value,
              animationDuration: 0,
              dataLabelSettings: const DataLabelSettings(isVisible: false),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _ForecastChart extends StatelessWidget {
  final String title;
  final Map<String, double> actual;
  final Map<String, double> forecast;
  final Color actualColor;
  final Color forecastColor;

  const _ForecastChart({
    required this.title,
    required this.actual,
    required this.forecast,
    required this.actualColor,
    required this.forecastColor,
  });

  @override
  Widget build(BuildContext context) {
    final keys = <String>{...actual.keys, ...forecast.keys};
    final categories = keys.toList()..sort((a, b) => a.compareTo(b));
    if (categories.isEmpty) {
      return _EmptyChart(
        message: context.trRaw('لا توجد بيانات كافية للتوقع'),
      );
    }
    final chartWidth = math.max(320.0, 90.0 * categories.length);
    final tooltip = _defaultTooltip();
    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: chartWidth,
        height: 300,
        child: SfCartesianChart(
          title: ChartTitle(text: context.trRaw(title)),
          enableAxisAnimation: false,
          plotAreaBorderWidth: 0,
          legend: Legend(isVisible: true, position: LegendPosition.bottom),
          primaryXAxis: CategoryAxis(labelRotation: 45),
          primaryYAxis: NumericAxis(),
          tooltipBehavior: tooltip,
          zoomPanBehavior: zoomPan,
          trackballBehavior: trackball,
          series: [
            LineSeries<_ChartData, String>(
              name: context.trRaw('فعلي'),
              color: actualColor,
              dataSource: categories
                  .map((c) => _ChartData(_displayChartLabel(c), actual[c] ?? 0))
                  .toList(),
              xValueMapper: (d, _) => d.label,
              yValueMapper: (d, _) => d.value,
              animationDuration: 0,
              dataLabelSettings: const DataLabelSettings(isVisible: false),
            ),
            LineSeries<_ChartData, String>(
              name: context.trRaw('متوقع'),
              color: forecastColor,
              dataSource: categories
                  .map((c) => _ChartData(_displayChartLabel(c), forecast[c] ?? 0))
                  .toList(),
              xValueMapper: (d, _) => d.label,
              yValueMapper: (d, _) => d.value,
              animationDuration: 0,
              dataLabelSettings: const DataLabelSettings(isVisible: false),
            ),
          ],
        ),
      ),
    );
  }
}

class _KpiItem {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  _KpiItem({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });
}

class _KpiCard extends StatelessWidget {
  final _KpiItem item;

  const _KpiCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: NeuCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: item.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(item.icon, color: item.color, size: 20),
            ),
            const SizedBox(height: 10),
            LocalizedText(
              item.title,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 6),
            LocalizedText(
              item.value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopList extends StatelessWidget {
  final String title;
  final List<MapEntry<String, double>> entries;

  const _TopList({required this.title, required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return NeuCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LocalizedText(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ...entries.map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(child: LocalizedText(AppFormatters.localizeDateKey(e.key))),
                  LocalizedText(_PdfUtils.formatNumber(e.value)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChart extends StatelessWidget {
  final String message;

  const _EmptyChart({required this.message});

  @override
  Widget build(BuildContext context) {
    return NeuCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Icon(Icons.bar_chart_outlined,
              size: 36, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 8),
          LocalizedText(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _LineAndPieCharts extends StatelessWidget {
  final List<_ChartData> data;
  final String primaryTitle;
  final Color accent;

  const _LineAndPieCharts({
    required this.data,
    required this.primaryTitle,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final chartWidth = math.max(280.0, 60.0 * data.length);
    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    final tooltip = _defaultTooltip();

    if (data.isEmpty) {
      return _EmptyChart(
        message: context.trRaw('لا توجد بيانات لعرضها ضمن الفترة المحددة'),
      );
    }

    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: chartWidth,
            height: 280,
            child: SfCartesianChart(
          title: ChartTitle(text: context.trRaw('$primaryTitle (خطي)')),
              enableAxisAnimation: false,
              plotAreaBorderWidth: 0,
              primaryXAxis: CategoryAxis(labelRotation: 45),
              primaryYAxis: NumericAxis(),
              zoomPanBehavior: zoomPan,
              trackballBehavior: trackball,
              tooltipBehavior: tooltip,
              series: <LineSeries<_ChartData, String>>[
                LineSeries<_ChartData, String>(
                  dataSource: data,
                  xValueMapper: (d, _) => d.label,
                  yValueMapper: (d, _) => d.value,
                  color: accent,
                  animationDuration: 0,
                  dataLabelSettings: const DataLabelSettings(isVisible: false),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 280,
          child: InteractiveViewer(
            minScale: 0.9,
            maxScale: 4,
            panEnabled: true,
            child: SfCircularChart(
              title: ChartTitle(text: context.trRaw('$primaryTitle (دائري)')),
              legend: Legend(
                isVisible: true,
                overflowMode: LegendItemOverflowMode.wrap,
              ),
              tooltipBehavior: tooltip,
              series: <PieSeries<_ChartData, String>>[
                PieSeries<_ChartData, String>(
                  dataSource: data,
                  xValueMapper: (d, _) => d.label,
                  yValueMapper: (d, _) => d.value,
                  animationDuration: 0,
                  dataLabelSettings: const DataLabelSettings(isVisible: false),
                )
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BarChart extends StatelessWidget {
  final List<_ChartData> data;
  final String title;
  final Color accent;

  const _BarChart({
    required this.data,
    required this.title,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final chartWidth = math.max(280.0, 70.0 * data.length);
    final tooltip = _defaultTooltip();
    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    if (data.isEmpty) {
      return _EmptyChart(
        message: context.trRaw('لا توجد بيانات لعرضها ضمن الفترة المحددة'),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: chartWidth,
        height: 300,
        child: SfCartesianChart(
          title: ChartTitle(text: context.trRaw(title)),
          enableAxisAnimation: false,
          plotAreaBorderWidth: 0,
          primaryXAxis: CategoryAxis(labelRotation: 45),
          primaryYAxis: NumericAxis(),
          tooltipBehavior: tooltip,
          zoomPanBehavior: zoomPan,
          trackballBehavior: trackball,
          series: <ColumnSeries<_ChartData, String>>[
            ColumnSeries<_ChartData, String>(
              dataSource: data,
              xValueMapper: (d, _) => d.label,
              yValueMapper: (d, _) => d.value,
              color: accent,
              animationDuration: 0,
              dataLabelSettings: const DataLabelSettings(isVisible: false),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutstandingTable extends StatelessWidget {
  final List<Map<String, dynamic>> rows;

  const _OutstandingTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _EmptyChart(
        message: context.trRaw('لا توجد مستحقات ضمن الفترة المحددة'),
      );
    }
    final money = AppFormatters.numberFormat('#,##0.00');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: LocalizedText('الطبيب')),
          DataColumn(label: LocalizedText('النِّسب')),
          DataColumn(label: LocalizedText('المدخلات')),
          DataColumn(label: LocalizedText('السلف')),
          DataColumn(label: LocalizedText('الخصومات')),
          DataColumn(label: LocalizedText('المدفوع')),
          DataColumn(label: LocalizedText('الصافي')),
        ],
        rows: rows.map((r) {
          return DataRow(
            cells: [
              DataCell(LocalizedText(r['doctorName']?.toString() ?? '—')),
              DataCell(LocalizedText(money.format(
                  (r['ratioSum'] as num?)?.toDouble() ?? 0.0))),
              DataCell(LocalizedText(money.format(
                  (r['directInput'] as num?)?.toDouble() ?? 0.0))),
              DataCell(LocalizedText(money.format(
                  (r['totalLoans'] as num?)?.toDouble() ?? 0.0))),
              DataCell(LocalizedText(money.format(
                  (r['totalDiscounts'] as num?)?.toDouble() ?? 0.0))),
              DataCell(LocalizedText(money.format(
                  (r['totalPaid'] as num?)?.toDouble() ?? 0.0))),
              DataCell(LocalizedText(money.format(
                  (r['netPay'] as num?)?.toDouble() ?? 0.0))),
            ],
          );
        }).toList(),
      ),
    );
  }
}

/*──────────────────────── القسم 1: الدخل بالتاريخ ────────────────────────*/
class _IncomeByDateWidget extends StatefulWidget {
  const _IncomeByDateWidget();
  @override
  State<_IncomeByDateWidget> createState() => _IncomeByDateWidgetState();
}

class _IncomeByDateWidgetState extends State<_IncomeByDateWidget> {
  DateTime? _startDate;
  DateTime? _endDate;
  Map<String, double> _incomeByDate = {};
  StreamSubscription<String>? _dbSub;
  Timer? _refreshDebounce;

  static const Set<String> _watchTables = {
    'patients',
    'patient_services',
    'financial_logs',
  };

  @override
  void initState() {
    super.initState();
    _loadIncome();
    _dbSub = DBService.instance.changes.listen((table) {
      if (!_watchTables.contains(table)) return;
      _scheduleRefresh();
    });
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _loadIncome();
    });
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadIncome() async {
    final range = _normalizedRange(_startDate, _endDate);
    final start = range.start ?? DateTime(2000, 1, 1);
    final end = range.end ?? DateTime(2100, 1, 1);
    final map = await DBService.instance.getIncomeByDateBetween(start, end);
    if (!mounted) return;
    setState(() => _incomeByDate = map);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _startDate = d);
      _loadIncome();
    }
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _endDate = d);
      _loadIncome();
    }
  }

  List<_ChartData> get _data =>
      _incomeByDate.entries
          .map((e) => _ChartData(_displayChartLabel(e.key), e.value))
          .toList()
        ..sort((a, b) => a.label.compareTo(b.label));

  double get _total => _safeTotal(_data);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _incomeByDate.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tableRows =
        rows.map((e) => [e.key, _PdfUtils.formatNumber(e.value)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header('تقرير الدخل بالتاريخ',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text(_PdfUtils.pdf('الإجمالي: ${_PdfUtils.formatNumber(_total)}'),
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          ..._PdfUtils.lineChartsFromMap(_incomeByDate,
              title: 'الدخل بالتاريخ (خطي)'),
          pw.SizedBox(height: 12),
          _PdfUtils.simpleTable(headers: ['التاريخ', 'الدخل'], rows: tableRows),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.shareDoc(doc, 'تقرير الدخل بالتاريخ');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'تقرير الدخل بالتاريخ');
  }

  void _reset() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _loadIncome();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = math.max(300.0, 60.0 * data.length);
    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    final tooltip = _defaultTooltip();

    return Column(
      children: [
        _FilterAndExportBar(
          title: 'الدخل بالتاريخ',
          start: _startDate,
          end: _endDate,
          onPickStart: _pickStart,
          onPickEnd: _pickEnd,
          onExportPdf: _exportPdf,
          onDownloadPdf: _downloadPdf,
          onReset: _reset,
        ),
        // شريحة إحصائية مختصرة
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: NeuCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.summarize_outlined, color: kPrimaryColor),
                const SizedBox(width: 8),
                LocalizedText('الإجمالي: ${_total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                // خطي (تكبير وتحريك)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: NeuCard(
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: chartWidth,
                        height: 300,
                        child: SfCartesianChart(
                          title: ChartTitle(text: context.trRaw('الدخل بالتاريخ (خطي)')),
                          enableAxisAnimation: false,
                          plotAreaBorderWidth: 0,
                          primaryXAxis: CategoryAxis(labelRotation: 45),
                          primaryYAxis: NumericAxis(),
                          zoomPanBehavior: zoomPan,
                          trackballBehavior: trackball,
                          tooltipBehavior: tooltip,
                          series: <LineSeries<_ChartData, String>>[
                            LineSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              animationDuration: 0,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // دائري مع InteractiveViewer
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: NeuCard(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(
                      width: 420,
                      height: 300,
                      child: InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 5,
                        panEnabled: true,
                        child: SfCircularChart(
                          title: ChartTitle(text: context.trRaw('نسبة الدخل (دائري)')),
                          legend: Legend(
                              isVisible: true,
                              overflowMode: LegendItemOverflowMode.wrap),
                          tooltipBehavior: tooltip,
                          series: <PieSeries<_ChartData, String>>[
                            PieSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              animationDuration: 0,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: false),
                            )
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/*──────────────────────── القسم 2: الاستهلاك بالتاريخ ────────────────────────*/
class _ConsumptionByDateWidget extends StatefulWidget {
  const _ConsumptionByDateWidget();
  @override
  State<_ConsumptionByDateWidget> createState() =>
      _ConsumptionByDateWidgetState();
}

class _ConsumptionByDateWidgetState extends State<_ConsumptionByDateWidget> {
  DateTime? _startDate;
  DateTime? _endDate;
  List<Consumption> _all = [];
  Map<String, double> _byDate = {};
  StreamSubscription<String>? _dbSub;
  Timer? _refreshDebounce;

  static const Set<String> _watchTables = {
    'consumptions',
    'items',
    'item_types',
  };

  @override
  void initState() {
    super.initState();
    _load();
    _dbSub = DBService.instance.changes.listen((table) {
      if (!_watchTables.contains(table)) return;
      _scheduleRefresh();
    });
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await DBService.instance.getAllConsumption();
    if (!mounted) return;
    _all = all;
    await _applyFilters();
  }

  Future<void> _applyFilters() async {
    Iterable<Consumption> filtered = _all;
    final range = _normalizedRange(_startDate, _endDate);
    final start = range.start;
    final end = range.end;
    if (start != null) {
      filtered = filtered
          .where((c) => c.date.isAfter(start.subtract(const Duration(days: 1))));
    }
    if (end != null) {
      filtered =
          filtered.where((c) => c.date.isBefore(end.add(const Duration(days: 1))));
    }
    final df = AppFormatters.dateFormat('yyyy-MM-dd');
    final m = <String, double>{};
    for (final c in filtered) {
      final k = df.format(c.date);
      m[k] = (m[k] ?? 0) + _safeNumber(c.amount);
    }
    if (!mounted) return;
    setState(() => _byDate = m);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _startDate = d);
      _applyFilters();
    }
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _byDate.entries
          .map((e) => _ChartData(_displayChartLabel(e.key), e.value))
          .toList()
        ..sort((a, b) => a.label.compareTo(b.label));

  double get _total => _safeTotal(_data);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _byDate.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tableRows =
        rows.map((e) => [e.key, _PdfUtils.formatNumber(e.value)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header('تقرير الاستهلاك بالتاريخ',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text(_PdfUtils.pdf('الإجمالي: ${_PdfUtils.formatNumber(_total)}'),
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          ..._PdfUtils.lineChartsFromMap(_byDate,
              title: 'الاستهلاك بالتاريخ (خطي)'),
          pw.SizedBox(height: 12),
          _PdfUtils.simpleTable(
              headers: ['التاريخ', 'الاستهلاك'], rows: tableRows),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.shareDoc(doc, 'تقرير الاستهلاك بالتاريخ');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'تقرير الاستهلاك بالتاريخ');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = math.max(300.0, 60.0 * data.length);
    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    final tooltip = _defaultTooltip();

    return Column(
      children: [
        _FilterAndExportBar(
          title: 'الاستهلاك بالتاريخ',
          start: _startDate,
          end: _endDate,
          onPickStart: _pickStart,
          onPickEnd: _pickEnd,
          onExportPdf: _exportPdf,
          onDownloadPdf: _downloadPdf,
          onReset: () {
            setState(() {
              _startDate = null;
              _endDate = null;
            });
            _applyFilters();
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: NeuCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.summarize_outlined, color: kPrimaryColor),
                const SizedBox(width: 8),
                LocalizedText('الإجمالي: ${_total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: NeuCard(
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: chartWidth,
                        height: 300,
                        child: SfCartesianChart(
                          title: ChartTitle(text: context.trRaw('الاستهلاك بالتاريخ (خطي)')),
                          enableAxisAnimation: false,
                          plotAreaBorderWidth: 0,
                          primaryXAxis: CategoryAxis(labelRotation: 45),
                          primaryYAxis: NumericAxis(),
                          zoomPanBehavior: zoomPan,
                          trackballBehavior: trackball,
                          tooltipBehavior: tooltip,
                          series: <LineSeries<_ChartData, String>>[
                            LineSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              animationDuration: 0,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: NeuCard(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(
                      width: 420,
                      height: 300,
                      child: InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 5,
                        panEnabled: true,
                        child: SfCircularChart(
                          title: ChartTitle(text: context.trRaw('نسبة الاستهلاك (دائري)')),
                          legend: Legend(
                              isVisible: true,
                              overflowMode: LegendItemOverflowMode.wrap),
                          tooltipBehavior: tooltip,
                          series: <PieSeries<_ChartData, String>>[
                            PieSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              animationDuration: 0,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/*──────────────────────── القسم 3: الدخل حسب الطبيب ────────────────────────*/
class _IncomeByDoctorWidget extends StatefulWidget {
  const _IncomeByDoctorWidget();

  @override
  State<_IncomeByDoctorWidget> createState() => _IncomeByDoctorWidgetState();
}

class _IncomeByDoctorWidgetState extends State<_IncomeByDoctorWidget> {
  DateTime? _startDate;
  DateTime? _endDate;
  Map<String, double> _byDoctor = {};
  StreamSubscription<String>? _dbSub;
  Timer? _refreshDebounce;

  static const Set<String> _watchTables = {
    'patients',
    'doctors',
    'patient_services',
    'financial_logs',
  };

  @override
  void initState() {
    super.initState();
    _load();
    _dbSub = DBService.instance.changes.listen((table) {
      if (!_watchTables.contains(table)) return;
      _scheduleRefresh();
    });
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    await _applyFilters();
  }

  Future<void> _applyFilters() async {
    final range = _normalizedRange(_startDate, _endDate);
    final start = range.start ?? DateTime(2000, 1, 1);
    final end = range.end ?? DateTime(2100, 1, 1);
    final m =
        await DBService.instance.getPatientPaymentsByDoctorBetween(start, end);
    if (!mounted) return;
    setState(() => _byDoctor = m);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _startDate = d);
      _applyFilters();
    }
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _byDoctor.entries
          .map((e) => _ChartData(_displayChartLabel(e.key), e.value))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));

  double get _total => _safeTotal(_data);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _byDoctor.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tableRows =
        rows.map((e) => [e.key, _PdfUtils.formatNumber(e.value)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header('تقرير الدخل حسب الطبيب',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text(_PdfUtils.pdf('الإجمالي: ${_PdfUtils.formatNumber(_total)}'),
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          ..._PdfUtils.barChartsFromMap(_byDoctor,
              title: 'الدخل حسب الطبيب (أعمدة)'),
          pw.SizedBox(height: 12),
          _PdfUtils.simpleTable(headers: ['الطبيب', 'الدخل'], rows: tableRows),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.shareDoc(doc, 'تقرير الدخل حسب الطبيب');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'تقرير الدخل حسب الطبيب');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = math.max(300.0, 70.0 * data.length);
    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    final tooltip = _defaultTooltip();

    return Column(
      children: [
        _FilterAndExportBar(
          title: 'الدخل حسب الطبيب',
          start: _startDate,
          end: _endDate,
          onPickStart: _pickStart,
          onPickEnd: _pickEnd,
          onExportPdf: _exportPdf,
          onDownloadPdf: _downloadPdf,
          onReset: () {
            setState(() {
              _startDate = null;
              _endDate = null;
            });
            _applyFilters();
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: NeuCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.summarize_outlined, color: kPrimaryColor),
                const SizedBox(width: 8),
                LocalizedText('الإجمالي: ${_total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: NeuCard(
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: chartWidth,
                        height: 320,
                        child: SfCartesianChart(
                          title: ChartTitle(text: context.trRaw('الدخل حسب الطبيب (أعمدة)')),
                          enableAxisAnimation: false,
                          plotAreaBorderWidth: 0,
                          primaryXAxis: CategoryAxis(labelRotation: 45),
                          primaryYAxis: NumericAxis(),
                          zoomPanBehavior: zoomPan,
                          trackballBehavior: trackball,
                          tooltipBehavior: tooltip,
                          series: <ColumnSeries<_ChartData, String>>[
                            ColumnSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              animationDuration: 0,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: NeuCard(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(
                      width: 420,
                      height: 300,
                      child: InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 5,
                        panEnabled: true,
                        child: SfCircularChart(
                          title: ChartTitle(text: context.trRaw('نسبة الدخل (دائري)')),
                          legend: Legend(
                              isVisible: true,
                              overflowMode: LegendItemOverflowMode.wrap),
                          tooltipBehavior: tooltip,
                          series: <PieSeries<_ChartData, String>>[
                            PieSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              animationDuration: 0,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/*──────────────────────── القسم 4: نوعية الاستهلاك ────────────────────────*/
class _ConsumptionTypeWidget extends StatefulWidget {
  const _ConsumptionTypeWidget();

  @override
  State<_ConsumptionTypeWidget> createState() => _ConsumptionTypeWidgetState();
}

class _ConsumptionTypeWidgetState extends State<_ConsumptionTypeWidget> {
  DateTime? _startDate;
  DateTime? _endDate;
  List<Consumption> _all = [];
  Map<String, double> _byType = {};
  StreamSubscription<String>? _dbSub;
  Timer? _refreshDebounce;

  static const Set<String> _watchTables = {
    'consumptions',
    'items',
    'item_types',
  };

  @override
  void initState() {
    super.initState();
    _load();
    _dbSub = DBService.instance.changes.listen((table) {
      if (!_watchTables.contains(table)) return;
      _scheduleRefresh();
    });
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await DBService.instance.getAllConsumption();
    if (!mounted) return;
    _all = all;
    await _applyFilters();
  }

  Future<void> _applyFilters() async {
    Iterable<Consumption> filtered = _all;
    final range = _normalizedRange(_startDate, _endDate);
    final start = range.start;
    final end = range.end;
    if (start != null) {
      filtered = filtered
          .where((c) => c.date.isAfter(start.subtract(const Duration(days: 1))));
    }
    if (end != null) {
      filtered =
          filtered.where((c) => c.date.isBefore(end.add(const Duration(days: 1))));
    }
    final m = <String, double>{};
    for (final c in filtered) {
      final noteRaw = (c.note ?? '').trim();
      final type = noteRaw.isEmpty ? 'غير محدد' : noteRaw;
      m[type] = (m[type] ?? 0) + _safeNumber(c.amount);
    }
    if (!mounted) return;
    setState(() => _byType = m);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _startDate = d);
      _applyFilters();
    }
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _byType.entries
          .map((e) => _ChartData(_displayChartLabel(e.key), e.value))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));

  double get _total => _safeTotal(_data);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _byType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tableRows =
        rows.map((e) => [e.key, _PdfUtils.formatNumber(e.value)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header('تقرير نوعية الاستهلاك',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text(_PdfUtils.pdf('الإجمالي: ${_PdfUtils.formatNumber(_total)}'),
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          ..._PdfUtils.barChartsFromMap(_byType,
              title: 'نوعية الاستهلاك (أعمدة)'),
          pw.SizedBox(height: 12),
          _PdfUtils.simpleTable(headers: ['النوع', 'القيمة'], rows: tableRows),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.shareDoc(doc, 'تقرير نوعية الاستهلاك');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'تقرير نوعية الاستهلاك');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = math.max(300.0, 70.0 * data.length);

    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    final tooltip = _defaultTooltip();

    return Column(
      children: [
        _FilterAndExportBar(
          title: 'نوعية الاستهلاك',
          start: _startDate,
          end: _endDate,
          onPickStart: _pickStart,
          onPickEnd: _pickEnd,
          onExportPdf: _exportPdf,
          onDownloadPdf: _downloadPdf,
          onReset: () {
            setState(() {
              _startDate = null;
              _endDate = null;
            });
            _applyFilters();
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: NeuCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.summarize_outlined, color: kPrimaryColor),
                const SizedBox(width: 8),
                LocalizedText('الإجمالي: ${_total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: NeuCard(
                    padding: const EdgeInsets.all(8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: chartWidth,
                        height: 320,
                        child: SfCartesianChart(
                          title: ChartTitle(text: context.trRaw('نوعية الاستهلاك (أعمدة)')),
                          enableAxisAnimation: false,
                          plotAreaBorderWidth: 0,
                          primaryXAxis: CategoryAxis(labelRotation: 45),
                          primaryYAxis: NumericAxis(),
                          zoomPanBehavior: zoomPan,
                          trackballBehavior: trackball,
                          tooltipBehavior: tooltip,
                          series: <ColumnSeries<_ChartData, String>>[
                            ColumnSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              animationDuration: 0,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: NeuCard(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(
                      width: 420,
                      height: 300,
                      child: InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 5,
                        panEnabled: true,
                        child: SfCircularChart(
                          title: ChartTitle(text: context.trRaw('نسبة الاستهلاك (دائري)')),
                          legend: Legend(
                              isVisible: true,
                              overflowMode: LegendItemOverflowMode.wrap),
                          tooltipBehavior: tooltip,
                          series: <PieSeries<_ChartData, String>>[
                            PieSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              animationDuration: 0,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/*──────────────────────── القسم 5: حصة الأطباء بالتاريخ ────────────────────────*/
class _DoctorShareByDateWidget extends StatefulWidget {
  const _DoctorShareByDateWidget();

  @override
  State<_DoctorShareByDateWidget> createState() =>
      _DoctorShareByDateWidgetState();
}

class _DoctorShareByDateWidgetState extends State<_DoctorShareByDateWidget> {
  DateTime? _startDate;
  DateTime? _endDate;
  Map<String, double> _shareByDate = {};
  StreamSubscription<String>? _dbSub;
  Timer? _refreshDebounce;

  static const Set<String> _watchTables = {
    'patient_services',
    'service_doctor_share',
    'medical_services',
    'doctors',
  };

  @override
  void initState() {
    super.initState();
    _load();
    _dbSub = DBService.instance.changes.listen((table) {
      if (!_watchTables.contains(table)) return;
      _scheduleRefresh();
    });
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    await _applyFilters();
  }

  Future<void> _applyFilters() async {
    final range = _normalizedRange(_startDate, _endDate);
    final from = range.start ?? DateTime(2000);
    final to = range.end ?? DateTime(2100);
    final map = await DBService.instance.getDoctorShareByDateBetween(from, to);
    if (!mounted) return;
    setState(() => _shareByDate = map);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _startDate = d);
      _applyFilters();
    }
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _shareByDate.entries
          .map((e) => _ChartData(_displayChartLabel(e.key), e.value))
          .toList()
        ..sort((a, b) => a.label.compareTo(b.label));

  double get _total => _safeTotal(_data);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _shareByDate.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final tableRows =
        rows.map((e) => [e.key, _PdfUtils.formatNumber(e.value)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header('تقرير حصة الأطباء بالتاريخ',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text(_PdfUtils.pdf('الإجمالي: ${_PdfUtils.formatNumber(_total)}'),
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          ..._PdfUtils.lineChartsFromMap(_shareByDate,
              title: 'حصة الأطباء (خطي)'),
          pw.SizedBox(height: 12),
          _PdfUtils.simpleTable(headers: ['التاريخ', 'الحصة'], rows: tableRows),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.shareDoc(doc, 'تقرير حصة الأطباء بالتاريخ');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'تقرير حصة الأطباء بالتاريخ');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = math.max(300.0, 60.0 * data.length);

    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    final tooltip = _defaultTooltip();

    return Column(
      children: [
        _FilterAndExportBar(
          title: 'حصة الأطباء بالتاريخ',
          start: _startDate,
          end: _endDate,
          onPickStart: _pickStart,
          onPickEnd: _pickEnd,
          onExportPdf: _exportPdf,
          onDownloadPdf: _downloadPdf,
          onReset: () {
            setState(() {
              _startDate = null;
              _endDate = null;
            });
            _applyFilters();
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: NeuCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.summarize_outlined, color: kPrimaryColor),
                const SizedBox(width: 8),
                LocalizedText('الإجمالي: ${_total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: NeuCard(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  width: chartWidth,
                  height: 300,
                  child: SfCartesianChart(
                    title: ChartTitle(text: context.trRaw('حصة الأطباء بالتاريخ (خطي)')),
                    enableAxisAnimation: false,
                    plotAreaBorderWidth: 0,
                    primaryXAxis: CategoryAxis(labelRotation: 45),
                    primaryYAxis: NumericAxis(),
                    zoomPanBehavior: zoomPan,
                    trackballBehavior: trackball,
                    tooltipBehavior: tooltip,
                    series: <LineSeries<_ChartData, String>>[
                      LineSeries<_ChartData, String>(
                        dataSource: data,
                        xValueMapper: (d, _) => d.label,
                        yValueMapper: (d, _) => d.value,
                        animationDuration: 0,
                        dataLabelSettings:
                            const DataLabelSettings(isVisible: false),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/*──────────────────────── القسم 6: مستحقات الأطباء ────────────────────────*/
class _DoctorOutstandingWidget extends StatefulWidget {
  const _DoctorOutstandingWidget();

  @override
  State<_DoctorOutstandingWidget> createState() =>
      _DoctorOutstandingWidgetState();
}

class _DoctorOutstandingWidgetState extends State<_DoctorOutstandingWidget> {
  DateTime _asOf = DateTime.now();
  bool _loading = false;
  List<Map<String, dynamic>> _rows = [];
  StreamSubscription<String>? _dbSub;
  Timer? _refreshDebounce;

  static const Set<String> _watchTables = {
    'employees',
    'employees_loans',
    'employees_discounts',
    'employees_salaries',
    'patient_services',
    'service_doctor_share',
  };

  DateFormat get _dateFmt => AppFormatters.dateFormat('yyyy-MM-dd');
  NumberFormat get _moneyFmt => AppFormatters.numberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    _load();
    _dbSub = DBService.instance.changes.listen((table) {
      if (!_watchTables.contains(table)) return;
      _scheduleRefresh();
    });
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final data =
          await DBService.instance.getDoctorOutstandingBalances(asOf: _asOf);
      if (!mounted) return;
      setState(() => _rows = data);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAsOf() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _asOf,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (picked != null) {
      if (!mounted) return;
      setState(() => _asOf =
          DateTime(picked.year, picked.month, picked.day, 23, 59, 59));
      _load();
    }
  }

  double get _totalNet => _rows.fold<double>(
      0.0,
      (sum, r) =>
          sum + _safeNumber((r['netPay'] as num?)?.toDouble() ?? 0.0));

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _rows.map((r) {
      final start = DateTime.tryParse('${r['periodStart'] ?? ''}');
      final end = DateTime.tryParse('${r['periodEnd'] ?? ''}');
      final period =
          '${start != null ? _dateFmt.format(start) : '—'} → ${end != null ? _dateFmt.format(end) : '—'}';
      return [
        r['doctorName']?.toString() ?? '—',
        period,
        _PdfUtils.formatNumber(
            (r['ratioSum'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber(
            (r['directInput'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber(
            (r['totalLoans'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber(
            (r['totalDiscounts'] as num?)?.toDouble() ?? 0.0),
        _PdfUtils.formatNumber(
            (r['netPay'] as num?)?.toDouble() ?? 0.0),
      ];
    }).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header('تقرير مستحقات الأطباء',
              subtitle: 'حتى تاريخ: ${_dateFmt.format(_asOf)}',
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text(
            _PdfUtils.pdf('الإجمالي: ${_PdfUtils.formatNumber(_totalNet)}'),
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 10),
          _PdfUtils.simpleTable(
            headers: [
              'الطبيب',
              'الفترة',
              'النسب',
              'مدخلات',
              'سلف',
              'خصومات',
              'الصافي'
            ],
            rows: rows,
          ),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.shareDoc(doc, 'تقرير مستحقات الأطباء');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'تقرير مستحقات الأطباء');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            children: [
              NeuCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: const Icon(Icons.account_balance_wallet,
                          color: kPrimaryColor, size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: LocalizedText('مستحقات الأطباء',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.start,
                        style:
                            TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TDateButton(
                      icon: Icons.event_rounded,
                      label: 'حتى تاريخ: ${_dateFmt.format(_asOf)}',
                      onTap: _pickAsOf,
                    ),
                  ),
                  const SizedBox(width: 10),
                  TOutlinedButton(
                    icon: Icons.picture_as_pdf,
                    label: 'تصدير',
                    onPressed: _exportPdf,
                  ),
                  const SizedBox(width: 8),
                  TOutlinedButton(
                    icon: Icons.download_rounded,
                    label: 'تنزيل',
                    onPressed: _downloadPdf,
                  ),
                  const SizedBox(width: 8),
                  TOutlinedButton(
                    icon: Icons.refresh_rounded,
                    label: 'تحديث',
                    onPressed: _load,
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _rows.isEmpty
                  ? const Center(child: LocalizedText('لا توجد بيانات'))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                      itemBuilder: (ctx, i) {
                        final r = _rows[i];
                        final start =
                            DateTime.tryParse('${r['periodStart'] ?? ''}');
                        final end =
                            DateTime.tryParse('${r['periodEnd'] ?? ''}');
                        final period =
                            '${start != null ? _dateFmt.format(start) : '—'} → ${end != null ? _dateFmt.format(end) : '—'}';
                        final ratio =
                            _safeNumber((r['ratioSum'] as num?)?.toDouble() ?? 0);
                        final direct =
                            _safeNumber((r['directInput'] as num?)?.toDouble() ?? 0);
                        final loans =
                            _safeNumber((r['totalLoans'] as num?)?.toDouble() ?? 0);
                        final discounts = _safeNumber(
                            (r['totalDiscounts'] as num?)?.toDouble() ?? 0);
                        final net =
                            _safeNumber((r['netPay'] as num?)?.toDouble() ?? 0);
                        return NeuCard(
                          padding: const EdgeInsets.all(12),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              (r['doctorName'] ?? '—').toString(),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800),
                            ),
                            subtitle: LocalizedText('الفترة: $period\n'
                              'النسب: ${_moneyFmt.format(ratio)}، '
                              'مدخلات: ${_moneyFmt.format(direct)}\n'
                              'سلف: ${_moneyFmt.format(loans)}، '
                              'خصومات: ${_moneyFmt.format(discounts)}\n'
                              'الصافي: ${_moneyFmt.format(net)}',
                            ),
                          ),
                        );
                      },
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemCount: _rows.length,
                    ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: LocalizedText('إجمالي المستحقات: ${_moneyFmt.format(_totalNet)}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/*──────────────────────── القسم 6: صافي الأرباح ────────────────────────*/
class _NetProfitWidget extends StatefulWidget {
  const _NetProfitWidget();

  @override
  State<_NetProfitWidget> createState() => _NetProfitWidgetState();
}

class _NetProfitWidgetState extends State<_NetProfitWidget> {
  DateTime? _startDate;
  DateTime? _endDate;

  Map<String, double> _netByDate = {};
  StreamSubscription<String>? _dbSub;
  Timer? _refreshDebounce;

  static const Set<String> _watchTables = {
    'patients',
    'patient_services',
    'consumptions',
    'purchases',
    'employees_salaries',
    'employees_loans',
    'employees_discounts',
    'financial_logs',
  };

  @override
  void initState() {
    super.initState();
    _load();
    _dbSub = DBService.instance.changes.listen((table) {
      if (!_watchTables.contains(table)) return;
      _scheduleRefresh();
    });
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _load();
    });
  }

  @override
  void dispose() {
    _dbSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    await _applyFilters();
  }

  Future<void> _applyFilters() async {
    final range = _normalizedRange(_startDate, _endDate);
    final from = range.start ?? DateTime(2000);
    final to = range.end ?? DateTime(2100);
    final net = await DBService.instance.getNetProfitByDateBetween(from, to);
    if (!mounted) return;
    setState(() => _netByDate = net);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _startDate = d);
      await _applyFilters();
    }
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: Localizations.localeOf(context),
    );
    if (d != null) {
      if (!mounted) return;
      setState(() => _endDate = d);
      await _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _netByDate.entries
          .map((e) => _ChartData(_displayChartLabel(e.key), e.value))
          .toList()
        ..sort((a, b) => a.label.compareTo(b.label));

  double get _total => _safeTotal(_data);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes = await ClinicProfileService.loadReportLogoBytes();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _netByDate.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final tableRows =
        rows.map((e) => [e.key, _PdfUtils.formatNumber(e.value)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        footer: (ctx) => _PdfUtils.footer(ctx, clinic),
        build: (_) => [
          _PdfUtils.header('تقرير صافي الأرباح بالتاريخ',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text(_PdfUtils.pdf('مجموع صافي الأيام: ${_PdfUtils.formatNumber(_total)}'),
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          ..._PdfUtils.lineChartsFromMap(_netByDate,
              title: 'صافي الأرباح (خطي)'),
          pw.SizedBox(height: 12),
          _PdfUtils.simpleTable(
              headers: ['التاريخ', 'الصافي'], rows: tableRows),
        ],
      ),
    );
    return doc;
  }

  Future<void> _exportPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.shareDoc(doc, 'تقرير صافي الأرباح بالتاريخ');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'تقرير صافي الأرباح بالتاريخ');
  }

  void _reset() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _applyFilters();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = math.max(300.0, 60.0 * data.length);

    final zoomPan = _defaultZoomPan();
    final trackball = _defaultTrackball();
    final tooltip = _defaultTooltip();

    return Column(
      children: [
        _FilterAndExportBar(
          title: 'صافي الأرباح بالتاريخ',
          start: _startDate,
          end: _endDate,
          onPickStart: _pickStart,
          onPickEnd: _pickEnd,
          onExportPdf: _exportPdf,
          onDownloadPdf: _downloadPdf,
          onReset: _reset,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: NeuCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.summarize_outlined, color: kPrimaryColor),
                const SizedBox(width: 8),
                LocalizedText('مجموع الصافي: ${_total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: NeuCard(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  width: chartWidth,
                  height: 300,
                  child: SfCartesianChart(
                    title: ChartTitle(text: context.trRaw('صافي الأرباح بالتاريخ (خطي)')),
                    enableAxisAnimation: false,
                    plotAreaBorderWidth: 0,
                    primaryXAxis: CategoryAxis(labelRotation: 45),
                    primaryYAxis: NumericAxis(),
                    zoomPanBehavior: zoomPan,
                    trackballBehavior: trackball,
                    tooltipBehavior: tooltip,
                    series: <LineSeries<_ChartData, String>>[
                      LineSeries<_ChartData, String>(
                        dataSource: data,
                        xValueMapper: (d, _) => d.label,
                        yValueMapper: (d, _) => d.value,
                        animationDuration: 0,
                        dataLabelSettings:
                            const DataLabelSettings(isVisible: false),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/*──────────────────────── أدوات مساعدة صغيرة ────────────────────────*/
String _subtitleRange(DateTime? from, DateTime? to) {
  final df = AppFormatters.dateFormat('yyyy-MM-dd');
  final range = _normalizedRange(from, to);
  final start = range.start;
  final end = range.end;
  if (start == null && end == null) return 'الفترة: الكل';
  final fs = start == null ? '...' : df.format(start);
  final ts = end == null ? '...' : df.format(end);
  return 'الفترة: $fs → $ts';
}

({DateTime? start, DateTime? end}) _normalizedRange(
  DateTime? start,
  DateTime? end,
) {
  if (start != null && end != null && end.isBefore(start)) {
    return (start: end, end: start);
  }
  return (start: start, end: end);
}
