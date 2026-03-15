// lib/screens/employees/finance/financial_logs_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';

/*── TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

/*── الخدمات ─*/
import 'package:aelmamclinic/services/logging_service.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';
import 'finance_access_guard.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';

class FinancialLogsScreen extends StatefulWidget {
  const FinancialLogsScreen({super.key});

  @override
  State<FinancialLogsScreen> createState() => _FinancialLogsScreenState();
}

class _FinancialLogsScreenState extends State<FinancialLogsScreen> {
  final LoggingService _loggingService = LoggingService();

  // كل السجلات + النتائج بعد الفلترة
  List<Map<String, dynamic>> _logs = [];
  List<Map<String, dynamic>> _filtered = [];

  bool _isLoading = true;

  // فلترة بالتاريخ
  DateTime? _startDate;
  DateTime? _endDate;

  // فلترة نصية
  final TextEditingController _searchCtrl = TextEditingController();

  // فلترة بحسب نوع العملية
  bool _showCreate = true;
  bool _showUpdate = true;
  bool _showDelete = true;

  // تنسيقات
  DateFormat get _justDate => AppFormatters.dateFormat('yyyy-MM-dd');
  NumberFormat get _moneyFmt => AppFormatters.numberFormat('#,##0.00');

  @override
  void initState() {
    super.initState();
    _fetchLogs();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchLogs() async {
    setState(() => _isLoading = true);
    try {
      // 🔧 خذ نسخة قابلة للتعديل؛ بعض الخدمات تُرجع قائمة read-only
      final src = await _loggingService.getLogs();
      final logs = List<Map<String, dynamic>>.from(src);

      // ترتيب تنازلي حسب الوقت إن وُجد
      logs.sort((a, b) {
        final ta = DateTime.tryParse('${a['timestamp'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final tb = DateTime.tryParse('${b['timestamp'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return tb.compareTo(ta);
      });

      if (!mounted) return;
      setState(() => _logs = logs);
      _applyFilter();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LocalizedText('خطأ في جلب السجلات: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // تحويل القيمة لأي نص قابل للبحث
  String _stringify(dynamic v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    try {
      return jsonEncode(v);
    } catch (_) {
      return v.toString();
    }
  }

  // قراءة مبلغ آمن دائمًا رقم
  double _amountOf(Map<String, dynamic> log) {
    final v = log['amount'];
    if (v is num) return v.toDouble();
    final p = double.tryParse('$v');
    return p ?? 0.0;
  }

  // لون نقطة العملية
  Color _opColor(String op) {
    switch (op) {
      case 'delete':
        return Colors.red;
      case 'update':
        return Colors.orange;
      default:
        return kPrimaryColor; // create/other
    }
  }

  // تنسيق التوقيت للعرض
  String _formatTimestamp(dynamic iso) {
    final s = iso?.toString() ?? '';
    final dt = DateTime.tryParse(s);
    if (dt == null) return s;
    return AppFormatters.formatDateTime(dt, pattern: 'yyyy-MM-dd – HH:mm');
  }

  // انتقاء تاريخ (من/إلى)
  Future<void> _pickDate({required bool isStart}) async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _startDate : _endDate) ?? DateTime.now(),
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
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = DateTime(picked.year, picked.month, picked.day, 0, 0, 0);
        } else {
          _endDate =
              DateTime(picked.year, picked.month, picked.day, 23, 59, 59, 999);
        }
      });
      _applyFilter();
    }
  }

  // فلترة شاملة
  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    final from = _startDate;
    final to = _endDate;

    final result = _logs.where((log) {
      // فلترة العملية
      final op = (_stringify(log['operation']).isEmpty
              ? 'create'
              : _stringify(log['operation']))
          .toLowerCase();
      if (op == 'create' && !_showCreate) return false;
      if (op == 'update' && !_showUpdate) return false;
      if (op == 'delete' && !_showDelete) return false;
      if (!['create', 'update', 'delete'].contains(op)) {
        if (!_showCreate && !_showUpdate && !_showDelete) return false;
      }

      // فلترة التاريخ
      final dtStr = log['timestamp']?.toString() ?? '';
      final dt = DateTime.tryParse(dtStr);
      if (dt != null) {
        if (from != null && dt.isBefore(from)) return false;
        if (to != null && dt.isAfter(to)) return false;
      }

      // فلترة النص
      if (q.isEmpty) return true;
      final haystack = [
        _stringify(log['transaction_type']),
        _stringify(log['description']),
        _stringify(log['employee_id']),
        _stringify(log['operation']),
        _stringify(log['modification_details']),
        _stringify(log['amount']),
        _stringify(dtStr),
      ].join(' | ').toLowerCase();

      return haystack.contains(q);
    }).toList();

    setState(() => _filtered = result);
  }

  void _clearDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    _applyFilter();
  }

  double get _filteredTotal => _filtered.fold(0.0, (p, e) => p + _amountOf(e));

  /*──────── تفاصيل السجل ────────*/
  void _showLogDetails(Map<String, dynamic> log) {
    final type = _stringify(log['transaction_type']);
    final op = _stringify(log['operation']).isEmpty
        ? 'create'
        : _stringify(log['operation']);
    final amt = _moneyFmt.format(_amountOf(log));
    final empId = _stringify(log['employee_id']).isEmpty
        ? 'N/A'
        : _stringify(log['employee_id']);
    final desc = _stringify(log['description']);
    final mods = _stringify(log['modification_details']);
    final tsRaw = _stringify(log['timestamp']);
    final ts = _formatTimestamp(tsRaw);

    showDialog(
      context: context,
      builder: (_) => Directionality(
        textDirection: Directionality.of(context),
        child: AlertDialog(
          title: const LocalizedText('تفاصيل السجل'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('نوع المعاملة:', type),
                _detailRow('نوع العملية:', op),
                _detailRow('المبلغ:', amt),
                _detailRow('معرف الموظف:', empId),
                if (desc.isNotEmpty) _detailRow('الوصف:', desc),
                if (mods.isNotEmpty) _detailRow('تفاصيل التعديل:', mods),
                _detailRow('التوقيت:', ts),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const LocalizedText('إغلاق')),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: RichText(
        text: TextSpan(
          text: '${context.trRaw(label)} ',
          style:
              TextStyle(fontWeight: FontWeight.bold, color: scheme.onSurface),
          children: [
            TextSpan(
                text: AppFormatters.localizeDigits(value),
                style: TextStyle(
                    fontWeight: FontWeight.normal, color: scheme.onSurface))
          ],
        ),
      ),
    );
  }

  /*──────── عنصر واحد في القائمة ────────*/
  Widget _logTile(Map<String, dynamic> log) {
    final scheme = Theme.of(context).colorScheme;
    final op = (_stringify(log['operation']).isEmpty
            ? 'create'
            : _stringify(log['operation']))
        .toLowerCase();
    final color = _opColor(op);
    final ts = _formatTimestamp(log['timestamp']);
    final amount = _moneyFmt.format(_amountOf(log));
    final type = _stringify(log['transaction_type']).isEmpty
        ? 'غير محدد'
        : _stringify(log['transaction_type']);
    final desc = _stringify(log['description']);
    final emp = _stringify(log['employee_id']);

    return NeuCard(
      onTap: () => _showLogDetails(log),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          decoration: BoxDecoration(
            color: kPrimaryColor.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(
            op == 'delete'
                ? Icons.delete_forever_rounded
                : op == 'update'
                    ? Icons.edit_rounded
                    : Icons.add_circle_outline_rounded,
            color: kPrimaryColor,
          ),
        ),
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsetsDirectional.only(end: 8),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            Expanded(
              child: LocalizedText(
                type,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: LocalizedText(
            [
              'العملية: $op   •   المبلغ: $amount',
              if (desc.isNotEmpty) 'التفاصيل: $desc',
              'التوقيت: $ts',
            ].join('\n'),
            style: TextStyle(color: scheme.onSurface.withValues(alpha: .8)),
          ),
        ),
        trailing: emp.isNotEmpty
            ? CircleAvatar(
                backgroundColor: kPrimaryColor.withValues(alpha: .10),
                child: LocalizedText(
                  emp,
                  style: const TextStyle(
                      color: kPrimaryColor, fontWeight: FontWeight.bold),
                ),
              )
            : null,
      ),
    );
  }

  /*──────── واجهة العرض ────────*/
  @override
  Widget build(BuildContext context) {
    return FinanceAccessGuard(
      child: Directionality(
        textDirection: Directionality.of(context),
        child: Scaffold(
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
              const Text('ELMAM CLINIC'),
            ],
          ),
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _fetchLogs,
            color: kPrimaryColor,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: kScreenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // شريط الفلاتر (TBIAN)
                  Row(
                    children: [
                      Expanded(
                        child: TDateButton(
                          icon: Icons.calendar_month_rounded,
                          label: _startDate == null
                              ? 'من تاريخ'
                              : _justDate.format(_startDate!),
                          onTap: () => _pickDate(isStart: true),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TDateButton(
                          icon: Icons.event_rounded,
                          label: _endDate == null
                              ? 'إلى تاريخ'
                              : _justDate.format(_endDate!),
                          onTap: () => _pickDate(isStart: false),
                        ),
                      ),
                      const SizedBox(width: 10),
                      TOutlinedButton(
                        icon: Icons.refresh_rounded,
                        label: 'مسح',
                        onPressed: (_startDate == null && _endDate == null)
                            ? null
                            : _clearDates,
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  TSearchField(
                    controller: _searchCtrl,
                    hint: 'ابحث في النوع/الوصف/الموظف/العملية/المبلغ...',
                    onChanged: (_) => _applyFilter(),
                    onClear: () {
                      _searchCtrl.clear();
                      _applyFilter();
                    },
                  ),

                  const SizedBox(height: 10),

                  // مفاتيح الإظهار + حبة الإجمالي
                  Row(
                    children: [
                      _opToggle('إضافة', _showCreate, (v) {
                        setState(() => _showCreate = v);
                        _applyFilter();
                      }),
                      const SizedBox(width: 8),
                      _opToggle('تعديل', _showUpdate, (v) {
                        setState(() => _showUpdate = v);
                        _applyFilter();
                      }),
                      const SizedBox(width: 8),
                      _opToggle('حذف', _showDelete, (v) {
                        setState(() => _showDelete = v);
                        _applyFilter();
                      }),
                      const Spacer(),
                      _pillStat(
                          'الإجمالي المعروض: ${_moneyFmt.format(_filteredTotal)}  •  ${_filtered.length} سجل'),
                    ],
                  ),

                  const SizedBox(height: 8),
                  const Divider(height: 1),

                  const SizedBox(height: 10),

                  if (_isLoading) ...[
                    const SizedBox(height: 120),
                    const Center(child: CircularProgressIndicator()),
                  ] else if (_filtered.isEmpty) ...[
                    const SizedBox(height: 120),
                    const Center(
                        child: LocalizedText('لا توجد سجلات مطابقة',
                            style: TextStyle(
                                fontSize: 16, color: Colors.black54))),
                  ] else ...[
                    ..._filtered.map((e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: _logTile(e),
                        )),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }

  /*──────── قطع واجهة صغيرة ────────*/

  Widget _opToggle(String label, bool value, ValueChanged<bool> onChanged) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          LocalizedText(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(width: 6),
          Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: kPrimaryColor),
        ],
      ),
    );
  }

  Widget _pillStat(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: LocalizedText(
        text,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}
