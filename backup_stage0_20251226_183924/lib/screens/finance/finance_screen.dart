//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\lib\screens\finance\finance_screen.dart
import 'dart:ui' as ui show TextDirection;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../services/db_service.dart';
import '../../../services/logging_service.dart';

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

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('yyyy-MM-dd');
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('الخلاصة المالية',
              style: TextStyle(fontWeight: FontWeight.bold)),
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [lightAccentColor, accentColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [veryLightBg, Colors.white, veryLightBg],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _pickStartDate,
                      child: Text(
                        _startDate == null
                            ? 'من تاريخ'
                            : dateFmt.format(_startDate!),
                        style: const TextStyle(color: Colors.black87),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _pickEndDate,
                      child: Text(
                        _endDate == null
                            ? 'إلى تاريخ'
                            : dateFmt.format(_endDate!),
                        style: const TextStyle(color: Colors.black87),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accentColor,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                    ),
                    onPressed: _calculate,
                    child: const Text('عرض',
                        style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _buildCard('مجموع المبالغ المدخلة من المرضى', _collected),
              _buildCard('مشتريات واستهلاكات المركز الطبي', _clinicConsumption),
              _buildCard(
                  'مبلغ النسب للأطباء من الأشعة/المختبر', _doctorsRatios),
              _buildCard(
                  'مدخلات الأطباء بعد خصم نسب المركز الطبي', _doctorsInputs),
              _buildCard('مجموع نسب المركز الطبي من كل الخدمات', _towerShare),
              _buildCard('مبالغ السلف المصروفة', _loansPaid),
              _buildCard('مبالغ الخصومات', _discountsTaken),
              _buildCard('مبالغ الرواتب والمستحقات المصروفة', _salariesPaid),
              _buildCard('الصافي/الأرباح', _netProfit),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(String title, double value) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(value.toStringAsFixed(2)),
      ),
    );
  }

  Future<void> _pickStartDate() async {
    final pick = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pick != null) setState(() => _startDate = pick);
  }

  Future<void> _pickEndDate() async {
    final pick = await showDatePicker(
      context: context,
      initialDate: _endDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pick != null) setState(() => _endDate = pick);
  }

  Future<void> _calculate() async {
    if (_startDate == null || _endDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر الفترة الزمنية أولاً')),
      );
      return;
    }
    final from = _startDate!;
    final to = _endDate!;

    final collectedVal =
        await DBService.instance.getSumPatientsBetween(from, to);
    final consumptionVal =
        await DBService.instance.getSumConsumptionBetween(from, to);

    double ratiosVal = 0, inputsVal = 0, towerVal = 0;
    try {
      ratiosVal =
          await DBService.instance.getSumAllDoctorShareBetween(from, to);
      inputsVal = await DBService.instance
          .getEffectiveSumAllDoctorInputBetween(from, to);
      towerVal = await DBService.instance.getSumAllTowerShareBetween(from, to);
    } catch (_) {}

    double loansVal = 0;
    for (var ln in await DBService.instance.getAllEmployeeLoans()) {
      final dt = DateTime.tryParse(ln['loanDateTime'] ?? '');
      if (dt != null &&
          dt.isAfter(from.subtract(const Duration(days: 1))) &&
          dt.isBefore(to.add(const Duration(days: 1)))) {
        loansVal += (ln['loanAmount'] ?? 0.0) as double;
      }
    }

    double discountsVal = 0;
    for (var ds in await DBService.instance.getAllEmployeeDiscounts()) {
      final dt = DateTime.tryParse(ds['discountDateTime'] ?? '');
      if (dt != null &&
          dt.isAfter(from.subtract(const Duration(days: 1))) &&
          dt.isBefore(to.add(const Duration(days: 1)))) {
        discountsVal += (ds['amount'] ?? 0.0) as double;
      }
    }

    double salariesVal = 0;
    for (var sal in await DBService.instance.getAllEmployeeSalaries()) {
      final dt = DateTime.tryParse(sal['paymentDate'] ?? '');
      if (dt != null &&
          dt.isAfter(from.subtract(const Duration(days: 1))) &&
          dt.isBefore(to.add(const Duration(days: 1)))) {
        salariesVal += (sal['netPay'] ?? 0.0) as double;
      }
    }

    final net = collectedVal - salariesVal - consumptionVal;

    LoggingService().logTransaction(
      transactionType: "FinanceSummary",
      operation: "create",
      amount: net,
      employeeId: null,
      description:
          "الخلاصة من ${DateFormat('yyyy-MM-dd').format(from)} إلى ${DateFormat('yyyy-MM-dd').format(to)}",
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
  }
}
