// lib/screens/consumption/list_consumption_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/export_service.dart';
import 'package:aelmamclinic/services/save_file_service.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';

class ListConsumptionScreen extends StatefulWidget {
  const ListConsumptionScreen({super.key});

  @override
  State<ListConsumptionScreen> createState() => _ListConsumptionScreenState();
}

class _ListConsumptionScreenState extends State<ListConsumptionScreen> {
  List<Consumption> _consumptions = [];
  List<Consumption> _filteredConsumptions = [];
  DateTime? _startDate;
  DateTime? _endDate;
  double _totalAmount = 0.0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  /// تحميل البيانات من قاعدة البيانات
  Future<void> _loadData() async {
    final data = await DBService.instance.getAllConsumption();
    setState(() {
      _consumptions = data;
      _filteredConsumptions = data;
      _calculateTotal();
    });
  }

  /// حساب الإجمالي
  void _calculateTotal() {
    final sum =
        _filteredConsumptions.fold<double>(0.0, (p, it) => p + it.amount);
    _totalAmount = sum;
  }

  /// اختيار تاريخ البداية
  Future<void> _pickStartDate() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate != null) {
      setState(() => _startDate = pickedDate);
    }
  }

  /// اختيار تاريخ النهاية
  Future<void> _pickEndDate() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate != null) {
      setState(() => _endDate = pickedDate);
    }
  }

  /// تطبيق التصفية
  void _applyFilter() {
    if (_startDate == null && _endDate == null) {
      setState(() {
        _filteredConsumptions = List.from(_consumptions);
        _calculateTotal();
      });
      return;
    }
    setState(() {
      _filteredConsumptions = _consumptions.where((item) {
        var inRange = true;
        if (_startDate != null) {
          inRange = item.date.isAtSameMomentAs(_startDate!) ||
              item.date.isAfter(_startDate!);
        }
        if (_endDate != null && inRange) {
          inRange = item.date.isAtSameMomentAs(_endDate!) ||
              item.date.isBefore(_endDate!);
        }
        return inRange;
      }).toList();
      _calculateTotal();
    });
  }

  void _clearFilter() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _filteredConsumptions = List.from(_consumptions);
      _calculateTotal();
    });
  }

  /// حذف عنصر
  Future<void> _deleteItem(int id) async {
    await DBService.instance.deleteConsumption(id);
    _loadData();
  }

  /// مشاركة الملف اعتمادًا على القائمة المُصفاة
  Future<void> _shareExcelFile() async {
    if (_filteredConsumptions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للمشاركة')),
      );
      return;
    }
    try {
      final bytes =
          await ExportService.exportConsumptionToExcel(_filteredConsumptions);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/كشف-استهلاك-العيادة.xlsx');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'ملف كشف استهلاك العيادة',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء المشاركة: $e')),
      );
    }
  }

  /// تنزيل الملف
  Future<void> _downloadExcelFile() async {
    if (_filteredConsumptions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد بيانات للتنزيل')),
      );
      return;
    }
    try {
      final bytes =
          await ExportService.exportConsumptionToExcel(_filteredConsumptions);
      await saveExcelFile(bytes, 'كشف-استهلاك-العيادة.xlsx');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حدث خطأ أثناء التنزيل: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              height: 24,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            const Text('استعراض المصروفات / الاستهلاكات'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'مشاركة',
            onPressed: _shareExcelFile,
            icon: const Icon(Icons.share_rounded),
          ),
          IconButton(
            tooltip: 'تنزيل',
            onPressed: _downloadExcelFile,
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: kScreenPadding,
          child: Column(
            children: [
              // رأس مع أيقونة
              NeuCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: kPrimaryColor.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: const Icon(
                        Icons.receipt_long_rounded,
                        color: kPrimaryColor,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'قائمة عمليات الصرف/الاستهلاك',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // اختيار فترة التصفية
              Row(
                children: [
                  Expanded(
                    child: _DateTile(
                      label: 'من تاريخ',
                      value: _startDate == null
                          ? null
                          : DateFormat('yyyy-MM-dd').format(_startDate!),
                      onTap: _pickStartDate,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _DateTile(
                      label: 'إلى تاريخ',
                      value: _endDate == null
                          ? null
                          : DateFormat('yyyy-MM-dd').format(_endDate!),
                      onTap: _pickEndDate,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // أزرار تصفية
              Row(
                children: [
                  NeuButton.primary(
                    label: 'عرض',
                    icon: Icons.filter_alt_rounded,
                    onPressed: _applyFilter,
                  ),
                  const SizedBox(width: 10),
                  NeuButton.flat(
                    label: 'إزالة التصفية',
                    icon: Icons.filter_alt_off_rounded,
                    onPressed: _clearFilter,
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // إجمالي المصروفات
              NeuCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.summarize_rounded, color: kPrimaryColor),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'إجمالي المصروفات / الاستهلاكات: ${_totalAmount.toStringAsFixed(2)}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // القائمة
              Expanded(
                child: _filteredConsumptions.isEmpty
                    ? Center(
                        child: Text(
                          'لا توجد بيانات',
                          style: TextStyle(
                            color: scheme.onSurface.withValues(alpha: .6),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _filteredConsumptions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (ctx, index) {
                          final c = _filteredConsumptions[index];
                          final date = DateFormat("yyyy-MM-dd").format(c.date);

                          return NeuCard(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Container(
                                decoration: BoxDecoration(
                                  color: kPrimaryColor.withValues(alpha: .1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.all(8),
                                child: const Icon(
                                  Icons.request_quote_rounded,
                                  color: kPrimaryColor,
                                  size: 22,
                                ),
                              ),
                              title: Text(
                                'مبلغ: ${c.amount.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14.5,
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  'تاريخ: $date | نوع: ${c.note}',
                                  style: TextStyle(
                                    color: scheme.onSurface.withValues(
                                      alpha: .65,
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              trailing: IconButton(
                                tooltip: 'حذف',
                                onPressed: () => _deleteItem(c.id!),
                                icon: const Icon(
                                  Icons.delete_rounded,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// عنصر اختيار التاريخ بأسلوب نيومورفيك
class _DateTile extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;

  const _DateTile({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.event_rounded, color: kPrimaryColor),
        title: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14.5),
        ),
        subtitle: value == null
            ? Text(
                'اضغط للاختيار',
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: .55),
                  fontWeight: FontWeight.w600,
                ),
              )
            : Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  value!,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: .8),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
        trailing: const Icon(Icons.chevron_left_rounded),
      ),
    );
  }
}
