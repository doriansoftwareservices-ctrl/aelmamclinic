// lib/screens/employees/finance/employees_finance_summary_screen.dart

import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/*── TBIAN ─*/
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/tbian_ui.dart';

/*── خدمات ─*/
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/logging_service.dart';

/// ── ثوابت الألوان الموحدة ──
const Color accentColor = Color(0xFF004A61);
const Color lightAccentColor = Color(0xFF9ED9E6);
const Color veryLightBg = Color(0xFFF7F9F9);

class EmployeesFinanceSummaryScreen extends StatefulWidget {
  const EmployeesFinanceSummaryScreen({super.key});

  @override
  State<EmployeesFinanceSummaryScreen> createState() =>
      _EmployeesFinanceSummaryScreenState();
}

class _EmployeesFinanceSummaryScreenState
    extends State<EmployeesFinanceSummaryScreen> {
  DateTime? _startDate;
  DateTime? _endDate;

  double _collected = 0;
  double _clinicConsumption = 0;
  double _doctorsRatios = 0;
  double _doctorsInputs = 0;
  double _towerShare = 0;
  double _loansPaid = 0;
  double _discountsTaken = 0;
  double _salariesPaid = 0;
  double _netProfit = 0;

  bool _busy = false;

  final DateFormat _dateFmt = DateFormat('yyyy-MM-dd');
  final NumberFormat _moneyFmt = NumberFormat('#,##0.00');

  double _asDouble(dynamic v) =>
      (v is num) ? v.toDouble() : double.tryParse('${v ?? 0}') ?? 0.0;

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
          child: SingleChildScrollView(
            padding: kScreenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'الخلاصة المالية',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 12),

                // شريط اختيار الفترة بأسلوب TBIAN
                Row(
                  children: [
                    Expanded(
                      child: TDateButton(
                        icon: Icons.calendar_month_rounded,
                        label: _startDate == null
                            ? 'من تاريخ'
                            : _dateFmt.format(_startDate!),
                        onTap: _pickStartDate,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TDateButton(
                        icon: Icons.event_rounded,
                        label: _endDate == null
                            ? 'إلى تاريخ'
                            : _dateFmt.format(_endDate!),
                        onTap: _pickEndDate,
                      ),
                    ),
                    const SizedBox(width: 10),
                    TOutlinedButton(
                      icon: Icons.refresh_rounded,
                      label: 'تفريغ',
                      onPressed: (_startDate == null && _endDate == null)
                          ? null
                          : _resetDates,
                    ),
                    const SizedBox(width: 10),
                    NeuButton.flat(
                      icon: Icons.play_arrow_rounded,
                      label: 'عرض',
                      onPressed: _busy ? null : _calculate,
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // بطاقات النتائج (Wrap نيومورفيزم)
                AnimatedOpacity(
                  opacity: _busy ? .5 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 16,
                    runSpacing: 18,
                    children: [
                      _statCard('مجموع المبالغ المدخلة من المرضى', _collected,
                          Icons.payments_outlined),
                      _statCard('مشتريات واستهلاكات المركز الطبي',
                          _clinicConsumption, Icons.local_hospital_outlined),
                      _statCard('مبلغ النسب للأطباء من الأشعة/المختبر',
                          _doctorsRatios, Icons.percent_outlined),
                      _statCard('مدخلات الأطباء بعد خصم نسب المركز الطبي',
                          _doctorsInputs, Icons.input_outlined),
                      _statCard('مجموع نسب المركز الطبي من كل الخدمات',
                          _towerShare, Icons.account_balance_outlined),
                      _statCard('مبالغ السلف المصروفة', _loansPaid,
                          Icons.request_quote_outlined),
                      _statCard('مبالغ الخصومات', _discountsTaken,
                          Icons.discount_outlined),
                      _statCard('مبالغ الرواتب والمستحقات المصروفة',
                          _salariesPaid, Icons.account_balance_wallet_outlined),
                      _statCard('الصافي/الأرباح', _netProfit,
                          Icons.attach_money_outlined,
                          emphasize: true),
                    ],
                  ),
                ),

                if (_busy) ...[
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /*──────── عناصر واجهة ────────*/
  Widget _statCard(String title, double value, IconData icon,
      {bool emphasize = false}) {
    final scheme = Theme.of(context).colorScheme;
    return NeuCard(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 260,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                decoration: BoxDecoration(
                  color: kPrimaryColor.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.all(10),
                child: Icon(icon, color: kPrimaryColor, size: 22),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: .85),
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _moneyFmt.format(value),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: ui.TextDirection.rtl,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: emphasize ? 20 : 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /*──────── اختيار تواريخ ────────*/
  Future<void> _pickStartDate() async {
    final pick = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pick != null) {
      setState(() => _startDate = DateTime(pick.year, pick.month, pick.day));
    }
  }

  Future<void> _pickEndDate() async {
    final pick = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pick != null) {
      setState(() => _endDate =
          DateTime(pick.year, pick.month, pick.day, 23, 59, 59, 999));
    }
  }

  void _resetDates() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
  }

  /*──────── الحساب ────────*/
  Future<void> _calculate() async {
    if (_startDate == null || _endDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر الفترة الزمنية أولاً')),
      );
      return;
    }
    if (_startDate!.isAfter(_endDate!)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تاريخ البداية أكبر من تاريخ النهاية')),
      );
      return;
    }

    setState(() => _busy = true);

    final from = _startDate!;
    final to = _endDate!;

    try {
      // مدخلات المرضى + الاستهلاكات
      final collectedVal =
          _asDouble(await DBService.instance.getSumPatientsBetween(from, to));
      final consumptionVal = _asDouble(
          await DBService.instance.getSumConsumptionBetween(from, to));

      // نسب/مدخلات/حصة المركز الطبي
      double ratiosVal = 0, inputsVal = 0, towerVal = 0;
      try {
        ratiosVal = _asDouble(
            await DBService.instance.getSumAllDoctorShareBetween(from, to));
        inputsVal = _asDouble(await DBService.instance
            .getEffectiveSumAllDoctorInputBetween(from, to));
        towerVal = _asDouble(
            await DBService.instance.getSumAllTowerShareBetween(from, to));
      } catch (_) {
        // تجاهُل أي خطأ تجميعي
      }

      // السلف
      double loansVal = 0;
      for (final ln in await DBService.instance.getAllEmployeeLoans()) {
        final dt = DateTime.tryParse('${ln['loanDateTime'] ?? ''}');
        if (dt != null && !dt.isBefore(from) && !dt.isAfter(to)) {
          loansVal += _asDouble(ln['loanAmount']);
        }
      }

      // الخصومات
      double discountsVal = 0;
      for (final ds in await DBService.instance.getAllEmployeeDiscounts()) {
        final dt = DateTime.tryParse('${ds['discountDateTime'] ?? ''}');
        if (dt != null && !dt.isBefore(from) && !dt.isAfter(to)) {
          discountsVal += _asDouble(ds['amount']);
        }
      }

      // الرواتب (صافي)
      double salariesVal = 0;
      for (final sal in await DBService.instance.getAllEmployeeSalaries()) {
        final dt = DateTime.tryParse('${sal['paymentDate'] ?? ''}');
        if (dt != null && !dt.isBefore(from) && !dt.isAfter(to)) {
          salariesVal += _asDouble(sal['netPay']);
        }
      }

      // صافي مبسّط وفق منطقك الحالي
      final net = collectedVal - salariesVal - consumptionVal;

      // سجل تشغيلي
      LoggingService().logTransaction(
        transactionType: "FinanceSummary",
        operation: "create",
        amount: net,
        employeeId: null,
        description:
            "الخلاصة من ${_dateFmt.format(from)} إلى ${_dateFmt.format(to)}",
      );

      setState(() {
        _collected = collectedVal;
        _clinicConsumption = consumptionVal;
        _doctorsRatios = ratiosVal;
        _doctorsInputs = inputsVal;
        _towerShare = towerVal;
        _loansPaid = loansVal;
        _discountsTaken = discountsVal;
        _salariesPaid = salariesVal;
        _netProfit = net;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر الحساب: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
