// lib/screens/prescriptions/prescription_list_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/prescription_pdf_service.dart';
import 'new_prescription_screen.dart';
import 'view_prescription_screen.dart';

/* تصميم TBIAN */
import 'package:aelmamclinic/core/neumorphism.dart';

/// معلومات مختصرة عن الوصفة تُستخدم فى القائمة
class _PrescriptionInfo {
  final int id;
  final int patientId;
  final String patientName;
  final String phone;
  final String? doctorName;
  final DateTime recordDate;

  _PrescriptionInfo({
    required this.id,
    required this.patientId,
    required this.patientName,
    required this.phone,
    required this.doctorName,
    required this.recordDate,
  });
}

class PrescriptionListScreen extends StatefulWidget {
  const PrescriptionListScreen({super.key});

  @override
  State<PrescriptionListScreen> createState() => _PrescriptionListScreenState();
}

class _PrescriptionListScreenState extends State<PrescriptionListScreen> {
  final _searchCtrl = TextEditingController();
  DateTime? _fromDate;
  DateTime? _toDate;

  List<_PrescriptionInfo> _all = [];
  List<_PrescriptionInfo> _filtered = [];

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_applyFilter);
    _searchCtrl.dispose();
    super.dispose();
  }

  /*──────────────── تحميل كل الوصفات ────────────────*/
  Future<void> _load() async {
    setState(() => _loading = true);
    final db = await DBService.instance.database;
    final rows = await db.rawQuery('''
      SELECT pr.id, pr.patientId, p.name AS patientName,
             IFNULL(p.phoneNumber, '')   AS phone,
             d.name                      AS doctorName,
             pr.recordDate
      FROM prescriptions pr
      JOIN patients      p ON pr.patientId = p.id
      LEFT JOIN doctors  d ON pr.doctorId  = d.id
      ORDER BY pr.recordDate DESC
    ''');

    final list = rows
        .map((r) => _PrescriptionInfo(
              id: r['id'] as int,
              patientId: r['patientId'] as int,
              patientName: r['patientName'] as String,
              phone: (r['phone'] as String?) ?? '',
              doctorName: r['doctorName'] as String?,
              recordDate: DateTime.parse(r['recordDate'] as String),
            ))
        .toList();

    setState(() {
      _all = list;
      _filtered = list;
      _loading = false;
    });
  }

  /*──────────────── التصفية (بحث + مدى زمنى) ────────────────*/
  void _applyFilter() {
    final q = _searchCtrl.text.toLowerCase().trim();
    setState(() {
      _filtered = _all.where((p) {
        final matchesText = q.isEmpty ||
            p.patientName.toLowerCase().contains(q) ||
            p.phone.toLowerCase().contains(q) ||
            (p.doctorName ?? '').toLowerCase().contains(q);

        bool inRange = true;
        if (_fromDate != null) {
          inRange = p.recordDate
              .isAfter(_fromDate!.subtract(const Duration(days: 1)));
        }
        if (_toDate != null && inRange) {
          inRange =
              p.recordDate.isBefore(_toDate!.add(const Duration(days: 1)));
        }
        return matchesText && inRange;
      }).toList();
    });
  }

  Future<void> _pickFromDate() async {
    final scheme = Theme.of(context).colorScheme;
    final d = await showDatePicker(
      context: context,
      initialDate: _fromDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: scheme,
        ),
        child: child!,
      ),
    );
    if (d != null) {
      setState(() => _fromDate = DateTime(d.year, d.month, d.day));
      _applyFilter();
    }
  }

  Future<void> _pickToDate() async {
    final scheme = Theme.of(context).colorScheme;
    final d = await showDatePicker(
      context: context,
      initialDate: _toDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: scheme,
        ),
        child: child!,
      ),
    );
    if (d != null) {
      setState(() => _toDate = DateTime(d.year, d.month, d.day));
      _applyFilter();
    }
  }

  void _resetDates() {
    setState(() {
      _fromDate = null;
      _toDate = null;
    });
    _applyFilter();
  }

  /*──────────────── تصدير PDF ────────────────*/
  Future<void> _exportAllToPdf() async {
    if (_filtered.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للتصدير')),
      );
      return;
    }

    final bytes = await PrescriptionPdfService.exportList(_filtered);
    final dir = await getTemporaryDirectory();
    final file = await PrescriptionPdfService.saveTempFile(bytes, dir);

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: 'قائمة الوصفات',
      ),
    );
  }

  /*──────────────── الواجهة ────────────────*/
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dateFmt = DateFormat('yyyy-MM-dd');

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('الوصفات الطبية'),
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [scheme.primaryContainer, scheme.primary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          actions: [
            IconButton(
              onPressed: _exportAllToPdf,
              tooltip: 'تصدير الكل PDF',
              icon: const Icon(Icons.picture_as_pdf),
            ),
          ],
        ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.surfaceContainerHigh,
                scheme.surface,
                scheme.surfaceContainerHigh
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Column(
            children: [
              /*── حقل البحث ─────────────────────────────*/
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'بحث بالاسم / الهاتف / الطبيب',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: scheme.surface,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(25),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),

              /*── نطاق التاريخ ─────────────────────────*/
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: scheme.primary,
                          foregroundColor: scheme.onPrimary,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(25)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _pickFromDate,
                        child: Text(_fromDate == null
                            ? 'من تاريخ'
                            : dateFmt.format(_fromDate!)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: scheme.primary,
                          foregroundColor: scheme.onPrimary,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(25)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _pickToDate,
                        child: Text(_toDate == null
                            ? 'إلى تاريخ'
                            : dateFmt.format(_toDate!)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: _resetDates,
                      borderRadius: BorderRadius.circular(25),
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(25),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Icon(Icons.refresh, color: scheme.primary),
                      ),
                    ),
                  ],
                ),
              ),

              /*── زر إضافة وصفة جديدة ───────────────────*/
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const NewPrescriptionScreen()),
                      );
                      await _load();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('إنشاء وصفة جديدة'),
                  ),
                ),
              ),

              /*── قائمة الوصفات ────────────────────────*/
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        color: scheme.primary,
                        onRefresh: _load,
                        child: _filtered.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  SizedBox(height: 120),
                                  Center(child: Text('لا توجد وصفات')),
                                ],
                              )
                            : ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.fromLTRB(12, 6, 12, 18),
                                itemCount: _filtered.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (_, i) {
                                  final p = _filtered[i];
                                  final dateStr = dateFmt.format(p.recordDate);

                                  return NeuCard(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    child: ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: Container(
                                        decoration: BoxDecoration(
                                          color: scheme.primary
                                              .withValues(alpha: .10),
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                        padding: const EdgeInsets.all(10),
                                        child: Icon(Icons.description_outlined,
                                            color: scheme.primary, size: 22),
                                      ),
                                      title: Text(
                                        p.patientName,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800),
                                      ),
                                      subtitle: Text(
                                        '$dateStr • د/${p.doctorName ?? 'غير محدَّد'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: .7)),
                                      ),
                                      trailing: const Icon(
                                          Icons.chevron_left_rounded),
                                      onTap: () async {
                                        // عرض التفاصيل أولاً، ومن هناك يمكن الطباعة أو الرجوع
                                        await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                ViewPrescriptionScreen(
                                                    prescriptionId: p.id),
                                          ),
                                        );
                                        await _load();
                                      },
                                      onLongPress: () async {
                                        // اختصار: فتح للتعديل
                                        await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                NewPrescriptionScreen(
                                                    prescriptionId: p.id),
                                          ),
                                        );
                                        await _load();
                                      },
                                    ),
                                  );
                                },
                              ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
