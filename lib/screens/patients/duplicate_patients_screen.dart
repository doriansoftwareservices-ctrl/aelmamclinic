// lib/screens/patients/duplicate_patients_screen.dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';

import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';
import 'package:aelmamclinic/core/formatters.dart';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/patient_service.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/utils/pdf_fonts.dart';
import 'package:aelmamclinic/utils/pdf_text.dart';
import 'package:aelmamclinic/utils/report_localizer.dart';
import 'view_patient_screen.dart';
import 'edit_patient_screen.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class DuplicatePatientsScreen extends StatefulWidget {
  final String phoneNumber;
  final String patientName;
  const DuplicatePatientsScreen({
    super.key,
    required this.phoneNumber,
    required this.patientName,
  });

  @override
  State<DuplicatePatientsScreen> createState() =>
      _DuplicatePatientsScreenState();
}

class _DuplicatePatientsScreenState extends State<DuplicatePatientsScreen> {
  final _searchCtrl = TextEditingController();
  DateFormat get _dateOnly => AppFormatters.dateFormat('yyyy-MM-dd');
  DateFormat get _dateTime => AppFormatters.dateFormat('yyyy-MM-dd HH:mm');

  final List<Patient> _duplicates = [];
  List<Patient> _filtered = [];
  final Map<int, List<PatientService>> _servicesByPatient = {};

  DateTime? _startDate;
  DateTime? _endDate;

  final Set<int> _selectedIds = {};
  final Set<int> _expandedIds = {};

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _selectedIds.clear();
      _expandedIds.clear();
    });

    final all = await DBService.instance.getAllPatients();
    final target = Formatters.normalizePhone(widget.phoneNumber);
    final dup = all
        .where((p) => Formatters.normalizePhone(p.phoneNumber) == target)
        .toList()
      ..sort((a, b) => b.registerDate.compareTo(a.registerDate));

    final svcMap = <int, List<PatientService>>{};
    for (final p in dup) {
      final svcs = await DBService.instance.getPatientServices(p.id!);
      svcMap[p.id!] = svcs;
    }

    setState(() {
      _duplicates
        ..clear()
        ..addAll(dup);
      _filtered
        ..clear()
        ..addAll(dup);
      _servicesByPatient
        ..clear()
        ..addAll(svcMap);
      _loading = false;
    });
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = _duplicates.where((p) {
        final inQuery = q.isEmpty
            ? true
            : ((p.doctorName ?? '').toLowerCase().contains(q) ||
                (_servicesByPatient[p.id!] ?? const <PatientService>[])
                    .any((s) => s.serviceName.toLowerCase().contains(q)));
        var inRange = true;
        if (_startDate != null) {
          inRange = p.registerDate
              .isAfter(_startDate!.subtract(const Duration(days: 1)));
        }
        if (_endDate != null && inRange) {
          inRange =
              p.registerDate.isBefore(_endDate!.add(const Duration(days: 1)));
        }
        return inQuery && inRange;
      }).toList();
    });
  }

  Future<void> _pickStart() async {
    final scheme = Theme.of(context).colorScheme;
    final d = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: AppFormatters.localeOf(context),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(primary: scheme.primary),
        ),
        child: child!,
      ),
    );
    if (d != null) {
      setState(() => _startDate = DateTime(d.year, d.month, d.day));
      _applyFilter();
    }
  }

  Future<void> _pickEnd() async {
    final scheme = Theme.of(context).colorScheme;
    final d = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: AppFormatters.localeOf(context),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(primary: scheme.primary),
        ),
        child: child!,
      ),
    );
    if (d != null) {
      setState(() => _endDate = DateTime(d.year, d.month, d.day));
      _applyFilter();
    }
  }

  void _resetDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _applyFilter();
  }

  void _toggleSelectAll() {
    if (_filtered.isEmpty) return;
    final allIds = _filtered.map((p) => p.id!).toSet();
    final allSelected = allIds.every(_selectedIds.contains);
    setState(() {
      if (allSelected) {
        _selectedIds.removeAll(allIds);
      } else {
        _selectedIds.addAll(allIds);
      }
    });
  }

  double _patientTotal(int id) {
    final list = _servicesByPatient[id] ?? const <PatientService>[];
    return list.fold<double>(0, (s, e) => s + e.serviceCost);
  }

  double get _selectedTotal =>
      _selectedIds.fold<double>(0, (sum, id) => sum + _patientTotal(id));

  Future<void> _deleteOne(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const LocalizedText('تأكيد الحذف'),
        content: const LocalizedText('سيتم حذف السجل نهائيًا. هل أنت متأكد؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const LocalizedText('إلغاء')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const LocalizedText('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    await DBService.instance.deletePatient(id);
    await _load();
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const LocalizedText('حذف المحدد'),
        content: LocalizedText('سيتم حذف ${_selectedIds.length} سجل. هل تريد المتابعة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const LocalizedText('إلغاء')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const LocalizedText('حذف')),
        ],
      ),
    );
    if (ok != true) return;

    for (final id in _selectedIds) {
      await DBService.instance.deletePatient(id);
    }
    await _load();
  }

  Future<void> _exportPdf() async {
    if (_selectedIds.isEmpty) return;
    final i18n = ReportLocalizer();

    pw.Font cairo;
    pw.Font cairoBold;
    try {
      final fonts = await loadPdfFonts();
      cairo = fonts.regular;
      cairoBold = fonts.bold;
    } catch (_) {
      cairo = pw.Font.helvetica();
      cairoBold = pw.Font.helveticaBold();
    }

    final clinic = await ClinicProfileService.loadActiveOrFallback();
    Uint8List? logoData;
    try {
      logoData = await ClinicProfileService.loadReportLogoBytes();
    } catch (_) {
      logoData = null;
    }

    final pdf = pw.Document();
    final rows = <List<String>>[];

    final selectedPatients =
        _duplicates.where((p) => _selectedIds.contains(p.id!)).toList();

    for (final p in selectedPatients) {
      final dateStr = i18n.formatDateTime(
        p.registerDate,
        pattern: 'yyyy-MM-dd HH:mm',
      );
      final svcs = _servicesByPatient[p.id!] ?? const <PatientService>[];
      if (svcs.isEmpty) {
        rows.add([p.name, '—', i18n.formatNumber(0), dateStr]);
      } else {
        for (final s in svcs) {
          rows.add([
            p.name,
            s.serviceName,
            i18n.formatNumber(s.serviceCost),
            dateStr
          ]);
        }
      }
    }

    final baseText = pw.TextStyle(font: cairo, fontSize: 12, height: 1.35);
    final boldText = pw.TextStyle(font: cairoBold, fontSize: 12, height: 1.35);
    final pageTheme = i18n.pageTheme(base: cairo, bold: cairoBold);

    pw.Widget thinDivider([double v = 6]) => pw.Padding(
          padding: pw.EdgeInsets.symmetric(vertical: v),
          child: pw.Container(height: 0.7, color: PdfColors.grey300),
        );

    pw.Widget infoRow(String label, String value) {
      final labelWidget = pw.Text(
        i18n.pdf(label),
        style: boldText,
        textAlign: i18n.startAlign,
      );
      final valueWidget = pw.Expanded(
        child: pw.Text(
          pdfText(value),
          style: baseText,
          textAlign: i18n.startAlign,
        ),
      );
      return pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: i18n.isRtl
            ? <pw.Widget>[valueWidget, pw.SizedBox(width: 14), labelWidget]
            : <pw.Widget>[labelWidget, pw.SizedBox(width: 14), valueWidget],
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pageTheme,
        header: (_) => i18n.buildLetterhead(
          clinic: clinic,
          regular: cairo,
          bold: cairoBold,
          logoData: logoData,
        ),
        footer: (ctx) => i18n.buildFooter(
          clinic: clinic,
          regular: cairo,
          pageNumber: ctx.pageNumber,
          pagesCount: ctx.pagesCount,
        ),
        build: (_) => [
          pw.SizedBox(height: 10),
          pw.Center(
            child: pw.Text(
              i18n.pdf(
                i18n.isRtl
                    ? 'سجلات ${widget.patientName} (${widget.phoneNumber})'
                    : 'Patient records ${widget.patientName} (${widget.phoneNumber})',
              ),
              style: pw.TextStyle(
                  font: cairoBold,
                  fontSize: 16,
                  color: PdfColors.blueGrey),
            ),
          ),
          pw.SizedBox(height: 8),
          thinDivider(),
          infoRow('اسم المريض', widget.patientName),
          infoRow('رقم الهاتف', widget.phoneNumber),
          pw.SizedBox(height: 10),
          pw.TableHelper.fromTextArray(
            headers: [
              i18n.pdf('المريض'),
              i18n.pdf('الخدمة'),
              i18n.pdf('السعر'),
              i18n.pdf('التاريخ')
            ],
            data: rows
                .map((r) => [
                      pdfText(r[0]),
                      pdfText(r[1]),
                      r[2],
                      r[3],
                    ])
                .toList(),
            headerStyle: pw.TextStyle(font: cairoBold, fontSize: 12),
            cellStyle: pw.TextStyle(font: cairo, fontSize: 12),
            headerDecoration:
                const pw.BoxDecoration(color: PdfColors.grey300),
            cellAlignments: <int, pw.Alignment>{
              0: i18n.isRtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
              1: i18n.isRtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
              2: pw.Alignment.center,
              3: pw.Alignment.center,
            },
            columnWidths: <int, pw.TableColumnWidth>{
              0: const pw.FlexColumnWidth(2),
              1: const pw.FlexColumnWidth(3),
              2: const pw.FlexColumnWidth(1),
              3: const pw.FlexColumnWidth(2),
            },
          ),
          pw.SizedBox(height: 10),
          thinDivider(),
          pw.Text(
              i18n.pdf(
                i18n.isRtl
                    ? 'الإجمالي المحدد: ${i18n.formatNumber(_selectedTotal)}'
                    : 'Selected total: ${i18n.formatNumber(_selectedTotal)}',
              ),
              textAlign: i18n.startAlign,
              style: pw.TextStyle(
                  font: cairoBold,
                  fontSize: 12,
                  color: PdfColors.blueGrey)),
        ],
      ),
    );

    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename: i18n.fileName(
        'سجلات المرضى المكررة',
        extension: 'pdf',
        suffixes: <Object?>[DateTime.now().millisecondsSinceEpoch],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedCount = _selectedIds.length;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          '${context.trRaw('سجلات')} ${widget.patientName}',
        ),
        actions: [
          if (selectedCount > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: LocalizedText('المحدَّد: $selectedCount',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          IconButton(
            tooltip: context.trRaw('تحديد/إلغاء الكل'),
            icon: const Icon(Icons.select_all),
            onPressed: _filtered.isEmpty ? null : _toggleSelectAll,
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: context.trRaw('تصدير المحدد إلى PDF'),
            onPressed: selectedCount == 0 ? null : _exportPdf,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // المحتوى
            RefreshIndicator(
              color: scheme.primary,
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
                children: [
                  // شريط البحث
                  TSearchField(
                    controller: _searchCtrl,
                    hint: 'ابحث بالخدمة أو الطبيب',
                    onChanged: (_) => _applyFilter(),
                    onClear: () {
                      _searchCtrl.clear();
                      _applyFilter();
                    },
                  ),
                  const SizedBox(height: 10),

                  // مرشحات التاريخ بنمط TBIAN
                  Row(
                    children: [
                      Expanded(
                        child: TDateButton(
                          icon: Icons.calendar_month_rounded,
                          label: _startDate == null
                              ? 'من تاريخ'
                              : _dateOnly.format(_startDate!),
                          onTap: _pickStart,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TDateButton(
                          icon: Icons.event_rounded,
                          label: _endDate == null
                              ? 'إلى تاريخ'
                              : _dateOnly.format(_endDate!),
                          onTap: _pickEnd,
                        ),
                      ),
                      const SizedBox(width: 10),
                      TOutlinedButton(
                        icon: Icons.refresh_rounded,
                        label: 'مسح',
                        onPressed: (_startDate == null && _endDate == null)
                            ? null
                            : _resetDates,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // القائمة
                  if (_loading) ...[
                    const SizedBox(height: 120),
                    const Center(child: CircularProgressIndicator()),
                  ] else if (_filtered.isEmpty) ...[
                    const SizedBox(height: 120),
                    const Center(child: LocalizedText('لا توجد نتائج')),
                  ] else ...[
                    ..._filtered.map((p) {
                      final pId = p.id!;
                      final svcs =
                          _servicesByPatient[pId] ?? const <PatientService>[];
                      final isExpanded = _expandedIds.contains(pId);
                      final dateStr = _dateTime.format(p.registerDate);
                      final total = _patientTotal(pId);

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: NeuCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          child: Column(
                            children: [
                              ListTile(
                                contentPadding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                leading: Checkbox(
                                  value: _selectedIds.contains(pId),
                                  activeColor: kPrimaryColor,
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        _selectedIds.add(pId);
                                      } else {
                                        _selectedIds.remove(pId);
                                      }
                                    });
                                  },
                                ),
                                title: Text(
                                  p.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800),
                                ),
                                subtitle: LocalizedText('$dateStr  •  الإجمالي: ${total.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: .75),
                                  ),
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    isExpanded
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      if (isExpanded) {
                                        _expandedIds.remove(pId);
                                      } else {
                                        _expandedIds.add(pId);
                                      }
                                    });
                                  },
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ViewPatientScreen(patient: p),
                                    ),
                                  ).then((_) => _load());
                                },
                                onLongPress: () {
                                  setState(() {
                                    if (_selectedIds.contains(pId)) {
                                      _selectedIds.remove(pId);
                                    } else {
                                      _selectedIds.add(pId);
                                    }
                                  });
                                },
                              ),

                              // تفاصيل موسعة
                              AnimatedCrossFade(
                                firstChild: const SizedBox.shrink(),
                                secondChild: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if ((p.doctorName ?? '')
                                          .trim()
                                          .isNotEmpty)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 8),
                                          child: Row(
                                            children: [
                                              const Icon(
                                                Icons.local_hospital_outlined,
                                                size: 18,
                                                color: kPrimaryColor,
                                              ),
                                              const SizedBox(width: 6),
                                              LocalizedText('الطبيب: ${p.doctorName!}',
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600)),
                                            ],
                                          ),
                                        ),
                                      if (svcs.isNotEmpty)
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 6,
                                          children: svcs
                                              .map((s) => Chip(
                                                    backgroundColor:
                                                        kPrimaryColor
                                                            .withValues(
                                                                alpha: .10),
                                                    label: Text(
                                                        '${s.serviceName} • ${s.serviceCost.toStringAsFixed(2)}'),
                                                  ))
                                              .toList(),
                                        )
                                      else
                                        const LocalizedText('لا توجد خدمات'),
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: TOutlinedButton(
                                              icon: Icons.visibility_outlined,
                                              label: 'عرض',
                                              onPressed: () {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        ViewPatientScreen(
                                                            patient: p),
                                                  ),
                                                ).then((_) => _load());
                                              },
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: TOutlinedButton(
                                              icon: Icons.edit_outlined,
                                              label: 'تعديل',
                                              onPressed: () {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        EditPatientScreen(
                                                            patient: p),
                                                  ),
                                                ).then((_) => _load());
                                              },
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          IconButton(
                                            tooltip: context.trRaw('حذف'),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.red,
                                            ),
                                            onPressed: () => _deleteOne(pId),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                crossFadeState: isExpanded
                                    ? CrossFadeState.showSecond
                                    : CrossFadeState.showFirst,
                                duration: const Duration(milliseconds: 200),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),

            // شريط سفلي للإجراءات الجماعية
            Align(
              alignment: Alignment.bottomCenter,
              child: NeuCard(
                margin: EdgeInsets.zero,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LocalizedText('المحدَّد: ${_selectedIds.length}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            LocalizedText('الإجمالي: ${_selectedTotal.toStringAsFixed(2)}'),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      TOutlinedButton(
                        icon: Icons.picture_as_pdf,
                        label: 'تصدير',
                        onPressed: _selectedIds.isEmpty ? null : _exportPdf,
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed:
                            _selectedIds.isEmpty ? null : _deleteSelected,
                        icon: const Icon(Icons.delete_forever,
                            color: Colors.white),
                        label: const LocalizedText('حذف المحدد',
                            style: TextStyle(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
