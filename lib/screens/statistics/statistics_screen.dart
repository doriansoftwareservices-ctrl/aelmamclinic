// lib/screens/statistics/statistics_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

/*── تصميم TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/save_file_service.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/consumption.dart';

/// نموذج بيانات بسيط للرسوم
class _ChartData {
  final String label;
  final double value;
  _ChartData(this.label, this.value);
}

/*──────────────────────── أدوات PDF ────────────────────────*/
class _PdfUtils {
  static Future<(pw.Font, pw.Font)> _loadFonts() async {
    final regular = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
    return (pw.Font.ttf(regular), pw.Font.ttf(bold));
  }

  static pw.PageTheme _pageTheme(pw.Font base, pw.Font bold) {
    return pw.PageTheme(
      margin: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: base, bold: bold),
    );
  }

  static pw.Widget header(
    String title, {
    String? subtitle,
    pw.ImageProvider? logo,
    ClinicProfile? clinic,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        if (clinic != null)
          pw.Row(
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(clinic.nameAr,
                        style: pw.TextStyle(
                            fontSize: 14, fontWeight: pw.FontWeight.bold)),
                    pw.Text(clinic.addressAr,
                        style: pw.TextStyle(
                            fontSize: 9, color: PdfColors.grey700)),
                    pw.Text('هاتف: ${clinic.phone}',
                        style: pw.TextStyle(
                            fontSize: 9, color: PdfColors.grey700)),
                  ],
                ),
              ),
              pw.Container(
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
              ),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(clinic.nameEn,
                        style: pw.TextStyle(
                            fontSize: 14, fontWeight: pw.FontWeight.bold)),
                    pw.Text(clinic.addressEn,
                        style: pw.TextStyle(
                            fontSize: 9, color: PdfColors.grey700)),
                    pw.Text('Tel: ${clinic.phone}',
                        style: pw.TextStyle(
                            fontSize: 9, color: PdfColors.grey700)),
                  ],
                ),
              ),
            ],
          )
        else
          pw.Row(
          children: [
            pw.Container(
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
            ),
            pw.SizedBox(width: 12),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('ELMAM CLINIC',
                      style: pw.TextStyle(
                          fontSize: 16, fontWeight: pw.FontWeight.bold)),
                  pw.Text(title, style: const pw.TextStyle(fontSize: 12)),
                  if (subtitle != null)
                    pw.Text(subtitle,
                        style: pw.TextStyle(
                            fontSize: 10, color: PdfColors.grey700)),
                ],
              ),
            ),
            ],
          ),
        if (clinic != null)
          pw.Column(
            children: [
              pw.SizedBox(height: 6),
              pw.Text(title,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                      fontSize: 12, fontWeight: pw.FontWeight.bold)),
              if (subtitle != null)
                pw.Text(subtitle,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(
                        fontSize: 10, color: PdfColors.grey700)),
            ],
          ),
        pw.SizedBox(height: 8),
        pw.Divider(color: PdfColors.grey300, thickness: .8),
        pw.SizedBox(height: 8),
      ],
    );
  }

  static pw.Widget simpleTable({
    required List<String> headers,
    required List<List<String>> rows,
  }) {
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
                  child: pw.Text(h,
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
                    child: pw.Text(c, textAlign: pw.TextAlign.center),
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
    final m = (maxY <= 0 || maxY.isNaN || maxY.isInfinite) ? 1 : maxY;
    final top = (m * 1.2);
    return pw.FixedAxis(
      List<double>.generate(6, (i) => top * i / 5.0),
      format: (v) => v.toStringAsFixed(0),
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
    final map = _sanitizeMap(rawMap);
    final entries = map.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final widgets = <pw.Widget>[];

    for (final part in _chunk(entries, size: chunkSize)) {
      var labels = part.map((e) => e.key).toList();
      var values = part.map((e) => e.value).toList();

      // إن كان لدينا نقطة واحدة فقط، نضيف نقطة وهمية لتفادي مشاكل step=0
      if (values.length == 1) {
        labels = List.of(labels)..add('');
        values = List.of(values)..add(0);
      }

      final maxY = values.fold<double>(0, math.max);

      widgets.addAll([
        if (title != null && entries.length <= chunkSize)
          pw.Text(title,
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
    final map = _sanitizeMap(rawMap);
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final widgets = <pw.Widget>[];

    for (final part in _chunk(entries, size: chunkSize)) {
      var labels = part.map((e) => e.key).toList();
      var values = part.map((e) => e.value).toList();

      // إن كان لدينا عمود واحد فقط، نضيف عمودًا صفرّيًا (label فارغ) لضمان ≥2
      if (values.length == 1) {
        labels = List.of(labels)..add('');
        values = List.of(values)..add(0);
      }

      final maxY = values.fold<double>(0, math.max);

      widgets.addAll([
        if (title != null && entries.length <= chunkSize)
          pw.Text(title,
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
  static Future<void> shareDoc(pw.Document doc, String prefix) async {
    final dir = await getTemporaryDirectory();
    final path =
        "${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.pdf";
    final file = File(path);
    await file.writeAsBytes(await doc.save());
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        text: prefix,
      ),
    );
  }

  /// تنزيل
  static Future<void> downloadDoc(
      BuildContext context, pw.Document doc, String prefix) async {
    final bytes = await doc.save();
    final fileName = "${prefix}_${DateTime.now().millisecondsSinceEpoch}.pdf";
    await saveFileBytes(bytes, fileName);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("تم حفظ الملف بنجاح")),
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
    final df = DateFormat('yyyy-MM-dd');
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
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
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
class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/logo2.png', // ← استبدال الشعار
                height: 24,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
              const Text('ELMAM CLINIC'),
            ],
          ),
          bottom: TabBar(
            controller: _tabController,
            indicatorColor: scheme.primary,
            labelColor: scheme.onSurface,
            unselectedLabelColor: scheme.onSurface.withValues(alpha: .6),
            tabs: const [
              Tab(icon: Icon(Icons.date_range), text: "الدخل بالتاريخ"),
              Tab(icon: Icon(Icons.calendar_today), text: "الاستهلاك بالتاريخ"),
              Tab(icon: Icon(Icons.person), text: "الدخل حسب الطبيب"),
              Tab(icon: Icon(Icons.category), text: "نوعية الاستهلاك"),
              Tab(icon: Icon(Icons.medical_services), text: "حصة الأطباء"),
              Tab(icon: Icon(Icons.attach_money), text: "صافي الأرباح"),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: const [
            _IncomeByDateWidget(),
            _ConsumptionByDateWidget(),
            _IncomeByDoctorWidget(),
            _ConsumptionTypeWidget(),
            _DoctorShareByDateWidget(),
            _NetProfitWidget(),
          ],
        ),
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
  List<Patient> _patients = [];
  Map<String, double> _incomeByDate = {};

  @override
  void initState() {
    super.initState();
    _loadPatients();
  }

  Future<void> _loadPatients() async {
    _patients = await DBService.instance.getAllPatients();
    _applyFilters();
  }

  Future<void> _applyFilters() async {
    Iterable<Patient> filtered = _patients;
    if (_startDate != null) {
      filtered = filtered.where((p) => p.registerDate
          .isAfter(_startDate!.subtract(const Duration(days: 1))));
    }
    if (_endDate != null) {
      filtered = filtered.where((p) =>
          p.registerDate.isBefore(_endDate!.add(const Duration(days: 1))));
    }
    final df = DateFormat('yyyy-MM-dd');
    final map = <String, double>{};
    for (final p in filtered) {
      final k = df.format(p.registerDate);
      map[k] = (map[k] ?? 0) + p.paidAmount;
    }
    setState(() => _incomeByDate = map);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
    );
    if (d != null) {
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
      locale: const Locale('ar', ''),
    );
    if (d != null) {
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _incomeByDate.entries.map((e) => _ChartData(e.key, e.value)).toList()
        ..sort((a, b) => a.label.compareTo(b.label));

  double get _total => _data.fold<double>(0, (s, d) => s + d.value);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes =
        (await rootBundle.load('assets/images/logo2.png')).buffer.asUint8List();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _incomeByDate.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tableRows =
        rows.map((e) => [e.key, e.value.toStringAsFixed(2)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        build: (_) => [
          _PdfUtils.header('تقرير الدخل بالتاريخ',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
    await _PdfUtils.shareDoc(doc, 'income_by_date');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'income_by_date');
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
    final chartWidth = (60.0 * data.length).clamp(300.0, 1200.0);

    final zoomPan = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableMouseWheelZooming: true,
      zoomMode: ZoomMode.x,
    );

    final trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
    );

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
                Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
                          title: ChartTitle(text: "الدخل بالتاريخ (Line)"),
                          primaryXAxis: CategoryAxis(labelRotation: 45),
                          primaryYAxis: NumericAxis(),
                          zoomPanBehavior: zoomPan,
                          trackballBehavior: trackball,
                          series: <LineSeries<_ChartData, String>>[
                            LineSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: true),
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
                          title: ChartTitle(text: "نسبة الدخل (Pie)"),
                          legend: Legend(
                              isVisible: true,
                              overflowMode: LegendItemOverflowMode.wrap),
                          series: <PieSeries<_ChartData, String>>[
                            PieSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: true),
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _all = await DBService.instance.getAllConsumption();
    _applyFilters();
  }

  Future<void> _applyFilters() async {
    Iterable<Consumption> filtered = _all;
    if (_startDate != null) {
      filtered = filtered.where(
          (c) => c.date.isAfter(_startDate!.subtract(const Duration(days: 1))));
    }
    if (_endDate != null) {
      filtered = filtered.where(
          (c) => c.date.isBefore(_endDate!.add(const Duration(days: 1))));
    }
    final df = DateFormat('yyyy-MM-dd');
    final m = <String, double>{};
    for (final c in filtered) {
      final k = df.format(c.date);
      m[k] = (m[k] ?? 0) + c.amount;
    }
    setState(() => _byDate = m);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
    );
    if (d != null) {
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
      locale: const Locale('ar', ''),
    );
    if (d != null) {
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _byDate.entries.map((e) => _ChartData(e.key, e.value)).toList()
        ..sort((a, b) => a.label.compareTo(b.label));

  double get _total => _data.fold<double>(0, (s, d) => s + d.value);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes =
        (await rootBundle.load('assets/images/logo2.png')).buffer.asUint8List();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _byDate.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tableRows =
        rows.map((e) => [e.key, e.value.toStringAsFixed(2)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        build: (_) => [
          _PdfUtils.header('تقرير الاستهلاك بالتاريخ',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
    await _PdfUtils.shareDoc(doc, 'consumption_by_date');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'consumption_by_date');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = (60.0 * data.length).clamp(300.0, 1200.0);

    final zoomPan = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableMouseWheelZooming: true,
      zoomMode: ZoomMode.x,
    );

    final trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
    );

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
                Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
                          title: ChartTitle(text: "الاستهلاك بالتاريخ (Line)"),
                          primaryXAxis: CategoryAxis(labelRotation: 45),
                          primaryYAxis: NumericAxis(),
                          zoomPanBehavior: zoomPan,
                          trackballBehavior: trackball,
                          series: <LineSeries<_ChartData, String>>[
                            LineSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: true),
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
                          title: ChartTitle(text: "نسبة الاستهلاك (Pie)"),
                          legend: Legend(
                              isVisible: true,
                              overflowMode: LegendItemOverflowMode.wrap),
                          series: <PieSeries<_ChartData, String>>[
                            PieSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: true),
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
  List<Patient> _patients = [];
  Map<String, double> _byDoctor = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _patients = await DBService.instance.getAllPatients();
    _applyFilters();
  }

  Future<void> _applyFilters() async {
    Iterable<Patient> filtered = _patients;
    if (_startDate != null) {
      filtered = filtered.where((p) => p.registerDate
          .isAfter(_startDate!.subtract(const Duration(days: 1))));
    }
    if (_endDate != null) {
      filtered = filtered.where((p) =>
          p.registerDate.isBefore(_endDate!.add(const Duration(days: 1))));
    }
    final m = <String, double>{};
    for (final p in filtered) {
      final nameRaw = p.doctorName;
      final doc = (nameRaw == null || nameRaw.trim().isEmpty)
          ? 'الأشعة/المختبر'
          : nameRaw.trim();
      m[doc] = (m[doc] ?? 0) + p.paidAmount;
    }
    setState(() => _byDoctor = m);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
    );
    if (d != null) {
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
      locale: const Locale('ar', ''),
    );
    if (d != null) {
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _byDoctor.entries.map((e) => _ChartData(e.key, e.value)).toList()
        ..sort((a, b) => b.value.compareTo(a.value));

  double get _total => _data.fold<double>(0, (s, d) => s + d.value);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes =
        (await rootBundle.load('assets/images/logo2.png')).buffer.asUint8List();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _byDoctor.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tableRows =
        rows.map((e) => [e.key, e.value.toStringAsFixed(2)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        build: (_) => [
          _PdfUtils.header('تقرير الدخل حسب الطبيب',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
    await _PdfUtils.shareDoc(doc, 'income_by_doctor');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'income_by_doctor');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = (70.0 * data.length).clamp(300.0, 1400.0);

    final zoomPan = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableMouseWheelZooming: true,
      zoomMode: ZoomMode.x,
    );

    final trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
    );

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
                Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
                          title: ChartTitle(text: "الدخل حسب الطبيب (Bar)"),
                          primaryXAxis: CategoryAxis(labelRotation: 45),
                          primaryYAxis: NumericAxis(),
                          zoomPanBehavior: zoomPan,
                          trackballBehavior: trackball,
                          series: <ColumnSeries<_ChartData, String>>[
                            ColumnSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: true),
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
                          title: ChartTitle(text: "نسبة الدخل (Pie)"),
                          legend: Legend(
                              isVisible: true,
                              overflowMode: LegendItemOverflowMode.wrap),
                          series: <PieSeries<_ChartData, String>>[
                            PieSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: true),
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _all = await DBService.instance.getAllConsumption();
    _applyFilters();
  }

  Future<void> _applyFilters() async {
    Iterable<Consumption> filtered = _all;
    if (_startDate != null) {
      filtered = filtered.where(
          (c) => c.date.isAfter(_startDate!.subtract(const Duration(days: 1))));
    }
    if (_endDate != null) {
      filtered = filtered.where(
          (c) => c.date.isBefore(_endDate!.add(const Duration(days: 1))));
    }
    final m = <String, double>{};
    for (final c in filtered) {
      final type = (c.note ?? 'غير محدد').trim().isEmpty ? 'غير محدد' : c.note!;
      m[type] = (m[type] ?? 0) + c.amount;
    }
    setState(() => _byType = m);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
    );
    if (d != null) {
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
      locale: const Locale('ar', ''),
    );
    if (d != null) {
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _byType.entries.map((e) => _ChartData(e.key, e.value)).toList()
        ..sort((a, b) => b.value.compareTo(a.value));

  double get _total => _data.fold<double>(0, (s, d) => s + d.value);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes =
        (await rootBundle.load('assets/images/logo2.png')).buffer.asUint8List();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _byType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final tableRows =
        rows.map((e) => [e.key, e.value.toStringAsFixed(2)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        build: (_) => [
          _PdfUtils.header('تقرير نوعية الاستهلاك',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
    await _PdfUtils.shareDoc(doc, 'consumption_by_type');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'consumption_by_type');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = (70.0 * data.length).clamp(300.0, 1400.0);

    final zoomPan = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableMouseWheelZooming: true,
      zoomMode: ZoomMode.x,
    );

    final trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
    );

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
                Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
                          title: ChartTitle(text: "نوعية الاستهلاك (Bar)"),
                          primaryXAxis: CategoryAxis(labelRotation: 45),
                          primaryYAxis: NumericAxis(),
                          zoomPanBehavior: zoomPan,
                          trackballBehavior: trackball,
                          series: <ColumnSeries<_ChartData, String>>[
                            ColumnSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: true),
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
                          title: ChartTitle(text: "نسبة الاستهلاك (Pie)"),
                          legend: Legend(
                              isVisible: true,
                              overflowMode: LegendItemOverflowMode.wrap),
                          series: <PieSeries<_ChartData, String>>[
                            PieSeries<_ChartData, String>(
                              dataSource: data,
                              xValueMapper: (d, _) => d.label,
                              yValueMapper: (d, _) => d.value,
                              dataLabelSettings:
                                  const DataLabelSettings(isVisible: true),
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _shareByDate = await DBService.instance.getDoctorShareByDateBetween(
      DateTime(2000),
      DateTime(2100),
    );
    _applyFilters();
  }

  Future<void> _applyFilters() async {
    final from = _startDate ?? DateTime(2000);
    final to = _endDate ?? DateTime(2100);
    DBService.instance.getDoctorShareByDateBetween(from, to).then((map) {
      if (!mounted) return;
      setState(() => _shareByDate = map);
    });
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
    );
    if (d != null) {
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
      locale: const Locale('ar', ''),
    );
    if (d != null) {
      setState(() => _endDate = d);
      _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _shareByDate.entries.map((e) => _ChartData(e.key, e.value)).toList()
        ..sort((a, b) => a.label.compareTo(b.label));

  double get _total => _data.fold<double>(0, (s, d) => s + d.value);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes =
        (await rootBundle.load('assets/images/logo2.png')).buffer.asUint8List();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _shareByDate.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final tableRows =
        rows.map((e) => [e.key, e.value.toStringAsFixed(2)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        build: (_) => [
          _PdfUtils.header('تقرير حصة الأطباء بالتاريخ',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
    await _PdfUtils.shareDoc(doc, 'doctor_share_by_date');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'doctor_share_by_date');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final chartWidth = (60.0 * data.length).clamp(300.0, 1200.0);

    final zoomPan = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableMouseWheelZooming: true,
      zoomMode: ZoomMode.x,
    );

    final trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
    );

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
                Text('الإجمالي: ${_total.toStringAsFixed(2)}',
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
                    title: ChartTitle(text: "حصة الأطباء بالتاريخ (Line)"),
                    primaryXAxis: CategoryAxis(labelRotation: 45),
                    primaryYAxis: NumericAxis(),
                    zoomPanBehavior: zoomPan,
                    trackballBehavior: trackball,
                    series: <LineSeries<_ChartData, String>>[
                      LineSeries<_ChartData, String>(
                        dataSource: data,
                        xValueMapper: (d, _) => d.label,
                        yValueMapper: (d, _) => d.value,
                        dataLabelSettings:
                            const DataLabelSettings(isVisible: true),
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

/*──────────────────────── القسم 6: صافي الأرباح ────────────────────────*/
class _NetProfitWidget extends StatefulWidget {
  const _NetProfitWidget();

  @override
  State<_NetProfitWidget> createState() => _NetProfitWidgetState();
}

class _NetProfitWidgetState extends State<_NetProfitWidget> {
  DateTime? _startDate;
  DateTime? _endDate;

  List<Patient> _patients = [];
  List<Consumption> _cons = [];
  List<Map<String, dynamic>> _discounts = [];
  Map<String, double> _netByDate = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _patients = await DBService.instance.getAllPatients();
    _cons = await DBService.instance.getAllConsumption();
    _discounts = await DBService.instance.getAllEmployeeDiscounts();
    await _applyFilters();
  }

  Future<void> _applyFilters() async {
    final from = _startDate ?? DateTime(2000);
    final to = _endDate ?? DateTime(2100);

    final df = DateFormat('yyyy-MM-dd');

    final income = <String, double>{};
    final share = <String, double>{};
    for (final p in _patients.where((p) =>
        p.registerDate.isAfter(from.subtract(const Duration(days: 1))) &&
        p.registerDate.isBefore(to.add(const Duration(days: 1))))) {
      final k = df.format(p.registerDate);
      income[k] = (income[k] ?? 0) + p.paidAmount;
    }

    final cons = <String, double>{};
    for (final c in _cons.where((c) =>
        c.date.isAfter(from.subtract(const Duration(days: 1))) &&
        c.date.isBefore(to.add(const Duration(days: 1))))) {
      final k = df.format(c.date);
      cons[k] = (cons[k] ?? 0) + c.amount;
    }

    final disc = <String, double>{};
    for (final d in _discounts.where((d) {
      final raw = d['discountDateTime']?.toString();
      if (raw == null || raw.isEmpty) return false;
      final dt = DateTime.tryParse(raw);
      if (dt == null) return false;
      return dt.isAfter(from.subtract(const Duration(days: 1))) &&
          dt.isBefore(to.add(const Duration(days: 1)));
    })) {
      final dt = DateTime.parse(d['discountDateTime'].toString());
      final k = df.format(dt);
      final amt = (d['amount'] as num?)?.toDouble() ?? 0.0;
      disc[k] = (disc[k] ?? 0) + amt;
    }

    final shareMap =
        await DBService.instance.getDoctorShareByDateBetween(from, to);
    final inputMap =
        await DBService.instance.getDoctorInputByDateBetween(from, to);

    share.addAll(shareMap);
    final days = <String>{}
      ..addAll(income.keys)
      ..addAll(cons.keys)
      ..addAll(disc.keys)
      ..addAll(share.keys)
      ..addAll(inputMap.keys);

    final net = <String, double>{};
    for (final k in days) {
      net[k] = (income[k] ?? 0) -
          (cons[k] ?? 0) -
          (disc[k] ?? 0) -
          (share[k] ?? 0) -
          (inputMap[k] ?? 0);
    }
    if (!mounted) return;
    setState(() => _netByDate = net);
  }

  Future<void> _pickStart() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('ar', ''),
    );
    if (d != null) {
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
      locale: const Locale('ar', ''),
    );
    if (d != null) {
      setState(() => _endDate = d);
      await _applyFilters();
    }
  }

  List<_ChartData> get _data =>
      _netByDate.entries.map((e) => _ChartData(e.key, e.value)).toList()
        ..sort((a, b) => a.label.compareTo(b.label));

  double get _total => _data.fold<double>(0, (s, d) => s + d.value);

  Future<pw.Document> _buildPdf() async {
    final (base, bold) = await _PdfUtils._loadFonts();
    final clinic = await ClinicProfileService.loadActiveOrFallback();
    final logoBytes =
        (await rootBundle.load('assets/images/logo2.png')).buffer.asUint8List();
    final logo = pw.MemoryImage(logoBytes);

    final rows = _netByDate.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final tableRows =
        rows.map((e) => [e.key, e.value.toStringAsFixed(2)]).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _PdfUtils._pageTheme(base, bold),
        build: (_) => [
          _PdfUtils.header('تقرير صافي الأرباح بالتاريخ',
              subtitle: _subtitleRange(_startDate, _endDate),
              logo: logo,
              clinic: clinic),
          pw.SizedBox(height: 6),
          pw.Text('مجموع صافي الأيام: ${_total.toStringAsFixed(2)}',
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
    await _PdfUtils.shareDoc(doc, 'net_profit_by_date');
  }

  Future<void> _downloadPdf() async {
    final doc = await _buildPdf();
    await _PdfUtils.downloadDoc(context, doc, 'net_profit_by_date');
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
    final chartWidth = (60.0 * data.length).clamp(300.0, 1200.0);

    final zoomPan = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableDoubleTapZooming: true,
      enableMouseWheelZooming: true,
      zoomMode: ZoomMode.x,
    );

    final trackball = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
    );

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
                Text('مجموع الصافي: ${_total.toStringAsFixed(2)}',
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
                    title: ChartTitle(text: "صافي الأرباح بالتاريخ (Line)"),
                    primaryXAxis: CategoryAxis(labelRotation: 45),
                    primaryYAxis: NumericAxis(),
                    zoomPanBehavior: zoomPan,
                    trackballBehavior: trackball,
                    series: <LineSeries<_ChartData, String>>[
                      LineSeries<_ChartData, String>(
                        dataSource: data,
                        xValueMapper: (d, _) => d.label,
                        yValueMapper: (d, _) => d.value,
                        dataLabelSettings:
                            const DataLabelSettings(isVisible: true),
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
  final df = DateFormat('yyyy-MM-dd');
  if (from == null && to == null) return 'الفترة: الكل';
  final fs = from == null ? '...' : df.format(from);
  final ts = to == null ? '...' : df.format(to);
  return 'الفترة: $fs → $ts';
}
