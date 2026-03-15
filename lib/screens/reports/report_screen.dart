// lib/screens/reports/report_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/widgets/localized_text.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  // القيم الأساسية
  int totalPatients = 0;
  int successfulAppointments = 0;
  int followUpCount = 0;
  double financialTotal = 0.0;
  double towerShareTotal = 0.0;

  // مدى تاريخي لحساب "حصة المركز" (افتراضيًا: الكل)
  DateTime? _fromDate;
  DateTime? _toDate;

  bool _loading = true;

  NumberFormat get _fmtInt => AppFormatters.numberFormat('#,##0');
  NumberFormat get _fmtMoney => AppFormatters.numberFormat('#,##0.00');
  DateFormat get _dateOnly => AppFormatters.dateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _loadReports();
  }

  Future<void> _loadReports() async {
    setState(() => _loading = true);
    try {
      final patients = await DBService.instance.getTotalPatients();
      final appointments = await DBService.instance.getSuccessfulAppointments();
      final followUps = await DBService.instance.getFollowUpCount();
      final financial = await DBService.instance.getFinancialTotal();

      // فترة آمنة تشمل "الكل" عند عدم اختيار تواريخ
      final from = _fromDate ?? DateTime(2000, 1, 1);
      final to = _toDate ?? DateTime(2100, 12, 31);
      final towerShare =
          await DBService.instance.getSumAllTowerShareBetween(from, to);

      if (!mounted) return;
      setState(() {
        totalPatients = patients;
        successfulAppointments = appointments;
        followUpCount = followUps;
        financialTotal = financial;
        towerShareTotal = towerShare;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickFromDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _fromDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _fromDate = DateTime(d.year, d.month, d.day));
      await _loadReports();
    }
  }

  Future<void> _pickToDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _toDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _toDate = DateTime(d.year, d.month, d.day));
      await _loadReports();
    }
  }

  void _resetDates() {
    setState(() {
      _fromDate = null;
      _toDate = null;
    });
    _loadReports();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const LocalizedText('التقارير والإحصائيات'),
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
            tooltip: context.trRaw('تحديث'),
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadReports,
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
        child: RefreshIndicator(
          color: scheme.primary,
          onRefresh: _loadReports,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
                // نطاق التاريخ (يؤثر على "حصة المركز" فقط)
                Row(
                  children: [
                    Expanded(
                      child: _DateChipButton(
                        label: _fromDate == null
                            ? 'من تاريخ'
                            : _dateOnly.format(_fromDate!),
                        icon: Icons.calendar_month_rounded,
                        onTap: _pickFromDate,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DateChipButton(
                        label: _toDate == null
                            ? 'إلى تاريخ'
                            : _dateOnly.format(_toDate!),
                        icon: Icons.event_rounded,
                        onTap: _pickToDate,
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
                const SizedBox(height: 18),

                // بطاقات الإحصاءات
                AnimatedOpacity(
                  opacity: _loading ? .4 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      _MetricCard(
                        icon: Icons.people_outline,
                        title: 'عدد المرضى',
                        value: _fmtInt.format(totalPatients),
                        color: scheme.primary,
                      ),
                      _MetricCard(
                        icon: Icons.event_available_outlined,
                        title: 'المواعيد الناجحة',
                        value: _fmtInt.format(successfulAppointments),
                        color: scheme.primary,
                      ),
                      _MetricCard(
                        icon: Icons.repeat_on_outlined,
                        title: 'عدد المتابعات',
                        value: _fmtInt.format(followUpCount),
                        color: scheme.primary,
                      ),
                      _MetricCard(
                        icon: Icons.attach_money_rounded,
                        title: 'إجمالي الدخل المالي',
                        value: _fmtMoney.format(financialTotal),
                        color: scheme.primary,
                      ),
                      _MetricCard(
                        icon: Icons.account_balance_outlined,
                        title: 'حصة المركز ضمن المدى',
                        subtitle: _rangeLabel(context),
                        value: _fmtMoney.format(towerShareTotal),
                        color: scheme.primary,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                if (_loading) const Center(child: CircularProgressIndicator()),
            ],
          ),
        ),
      ),
    );
  }

  String _rangeLabel(BuildContext context) {
    if (_fromDate == null && _toDate == null) return context.trRaw('كل الفترات');
    final f = _fromDate != null ? _dateOnly.format(_fromDate!) : '—';
    final t = _toDate != null ? _dateOnly.format(_toDate!) : '—';
    return context.trRaw('الفترة: $f → $t');
  }
}

/*──────── عنصر بطاقة إحصاء بنمط TBIAN ────────*/
class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String? subtitle;
  final Color color;

  const _MetricCard({
    required this.icon,
    required this.title,
    required this.value,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .06),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .3)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(height: 12),
          LocalizedText(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface.withValues(alpha: .85),
              fontWeight: FontWeight.w800,
              fontSize: 14.5,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            LocalizedText(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .6),
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 6),
          LocalizedText(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w900,
              fontSize: 20,
            ),
          ),
        ],
      ),
    );
  }
}

/*──────── زر اختيار تاريخ بشكل شارة ────────*/
class _DateChipButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _DateChipButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(25),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(25),
          border: Border.all(color: scheme.primary.withValues(alpha: .25)),
        ),
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(8),
              child: Icon(icon, color: scheme.primary, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: LocalizedText(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
