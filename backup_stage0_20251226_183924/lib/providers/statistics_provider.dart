// lib/providers/statistics_provider.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/models/alert_setting.dart';
import 'package:aelmamclinic/models/item.dart';

/// يجمع إحصاءات حيّة لتعبئة بطاقات Hero في لوحة الإحصاءات.
class StatisticsProvider extends ChangeNotifier {
  StatisticsProvider() {
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    _startPolling();
    refresh();
  }

  Timer? _pollTimer;
  void _startPolling() {
    _pollTimer ??= Timer.periodic(const Duration(seconds: 5), (_) async {
      final db = DBService.instance;
      if (await db.isStatisticsDirty()) {
        await refresh();
        await db.clearStatisticsDirty();
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  late DateTime _from;
  late DateTime _to;

  DateTime get from => _from;
  DateTime get to => _to;

  void setRange({required DateTime from, required DateTime to}) {
    _from = DateTime(from.year, from.month, from.day);
    _to = DateTime(to.year, to.month, to.day, 23, 59, 59);
    refresh();
  }

  // ───── القيم الحسابية ─────
  double _monthlyRevenue = 0.0;
  double _monthlyExpense = 0.0;
  double _monthlyDoctorRatios = 0.0;
  double _monthlyDoctorInputs = 0.0;
  double _monthlyTowerShare = 0.0;
  double _monthlyLoansPaid = 0.0;
  double _monthlyDiscounts = 0.0;
  double _monthlySalariesPaid = 0.0;
  double _monthlyNetProfit = 0.0;

  int _monthlyPatients = 0;
  int _lowStockCount = 0;
  int _todayConfirmed = 0;
  int _todayFollowUps = 0;
  int _totalPatientsAll = 0;
  int _outOfStockItems = 0;
  double _pendingLoans = 0.0;

  bool _busy = false;

  // ───── getters ─────
  double get monthlyRevenue => _monthlyRevenue;
  double get monthlyExpense => _monthlyExpense;
  double get monthlyDoctorRatios => _monthlyDoctorRatios;
  double get monthlyDoctorInputs => _monthlyDoctorInputs;
  double get monthlyTowerShare => _monthlyTowerShare;
  double get monthlyLoansPaid => _monthlyLoansPaid;
  double get monthlyDiscounts => _monthlyDiscounts;
  double get monthlySalariesPaid => _monthlySalariesPaid;
  double get monthlyNetProfit => _monthlyNetProfit;

  int get monthlyPatients => _monthlyPatients;
  int get lowStockCount => _lowStockCount;
  int get todayConfirmed => _todayConfirmed;
  int get todayFollowUps => _todayFollowUps;
  int get totalPatientsAll => _totalPatientsAll;
  int get outOfStockItems => _outOfStockItems;
  double get pendingLoans => _pendingLoans;

  bool get busy => _busy;

  final _currency =
      NumberFormat.currency(locale: 'ar', symbol: '', decimalDigits: 0);
  String get fmtRevenue => _currency.format(_monthlyRevenue);
  String get fmtExpense => _currency.format(_monthlyExpense);
  String get fmtDoctorRatios => _currency.format(_monthlyDoctorRatios);
  String get fmtDoctorInputs => _currency.format(_monthlyDoctorInputs);
  String get fmtTowerShare => _currency.format(_monthlyTowerShare);
  String get fmtLoansPaid => _currency.format(_monthlyLoansPaid);
  String get fmtDiscounts => _currency.format(_monthlyDiscounts);
  String get fmtSalariesPaid => _currency.format(_monthlySalariesPaid);
  String get fmtNetProfit => _currency.format(_monthlyNetProfit);
  String get fmtPendingLoans => _currency.format(_pendingLoans);

  /// تحميل / تحديث جميع الإحصاءات
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();

    final db = DBService.instance;

    // 1) إيرادات المرضى
    final revenue = await db.getSumPatientsBetween(_from, _to);
    // 2) استهلاكات المركز
    final expense = await db.getSumConsumptionBetween(_from, _to);
    // 3) نسب الأطباء
    final ratios = await db.getSumAllDoctorShareBetween(_from, _to);
    // 4) مدخلات الأطباء بعد خصم المركز
    final inputs = await db.getEffectiveSumAllDoctorInputBetween(_from, _to);
    // 5) حصّة المركز
    final tower = await db.getSumAllTowerShareBetween(_from, _to);
    // 6) سلف مصروفة
    final loansRaw = await db.database.then((d) => d.rawQuery(
        'SELECT SUM(loanAmount) AS total FROM employees_loans WHERE loanDateTime BETWEEN ? AND ?',
        [_from.toIso8601String(), _to.toIso8601String()]));
    final loans = (loansRaw.first['total'] as num?)?.toDouble() ?? 0.0;
    // 7) خصومات
    final discRaw = await db.database.then((d) => d.rawQuery(
        'SELECT SUM(amount) AS total FROM employees_discounts WHERE discountDateTime BETWEEN ? AND ?',
        [_from.toIso8601String(), _to.toIso8601String()]));
    final discounts = (discRaw.first['total'] as num?)?.toDouble() ?? 0.0;
    // 8) رواتب
    final salRaw = await db.database.then((d) => d.rawQuery(
        'SELECT SUM(netPay) AS total FROM employees_salaries WHERE paymentDate BETWEEN ? AND ?',
        [_from.toIso8601String(), _to.toIso8601String()]));
    final salaries = (salRaw.first['total'] as num?)?.toDouble() ?? 0.0;
    // صافي الربح
    final netProfit = revenue - salaries - expense;

    // 9) تعداد المرضى
    final monthlyPts = await _countPatientsBetween(_from, _to);
    // 10) تنبيهات المخزون المنخفض
    final lowStock = await _getLowStockCount();
    // 11) استرجاع جميع العودات وحساب اليوم
    final allReturns = await db.getAllReturns();
    final now = DateTime.now();
    final dueReturns = allReturns
        .where((r) => r.date.isBefore(now) || r.date.isAtSameMomentAs(now))
        .toList();
    final todayConf = dueReturns.length;
    // 12) حساب المتابعات حسب SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final seenIds = (prefs.getStringList('seen_reminder_ids') ?? [])
        .map((e) => int.tryParse(e) ?? 0)
        .toSet();
    final todayFoll = dueReturns.where((r) => seenIds.contains(r.id)).length;

    // 13) بيانات إضافية
    final totalPts = await db.getTotalPatients();
    final outOfStock = await _getOutOfStockCount();
    final pendLoans = await _getPendingLoansSum();

    // تخزين القيم
    _monthlyRevenue = revenue;
    _monthlyExpense = expense;
    _monthlyDoctorRatios = ratios;
    _monthlyDoctorInputs = inputs;
    _monthlyTowerShare = tower;
    _monthlyLoansPaid = loans;
    _monthlyDiscounts = discounts;
    _monthlySalariesPaid = salaries;
    _monthlyNetProfit = netProfit;

    _monthlyPatients = monthlyPts;
    _lowStockCount = lowStock;
    _todayConfirmed = todayConf;
    _todayFollowUps = todayFoll;

    _totalPatientsAll = totalPts;
    _outOfStockItems = outOfStock;
    _pendingLoans = pendLoans;

    _busy = false;
    notifyListeners();
  }

  Future<int> _getLowStockCount() async {
    final sql = '''
      SELECT COUNT(*) AS cnt
        FROM ${AlertSetting.table} AS a
        JOIN ${Item.table}         AS i ON i.id = a.item_id
       WHERE a.is_enabled = 1
         AND i.stock      <= a.threshold
    ''';
    final raw =
        await DBService.instance.database.then((db) => db.rawQuery(sql));
    return raw.isEmpty ? 0 : (raw.first['cnt'] as int? ?? 0);
  }

  Future<int> _countPatientsBetween(DateTime f, DateTime t) async {
    final raw = await DBService.instance.database.then((db) => db.rawQuery(
          'SELECT COUNT(*) AS cnt FROM patients WHERE registerDate BETWEEN ? AND ?',
          [f.toIso8601String(), t.toIso8601String()],
        ));
    return raw.isEmpty ? 0 : (raw.first['cnt'] as int? ?? 0);
  }

  Future<int> _getOutOfStockCount() async {
    final raw = await DBService.instance.database.then((db) => db.rawQuery(
          'SELECT COUNT(*) AS cnt FROM ${Item.table} WHERE stock = 0',
        ));
    return raw.isEmpty ? 0 : (raw.first['cnt'] as int? ?? 0);
  }

  Future<double> _getPendingLoansSum() async {
    final raw = await DBService.instance.database.then((db) => db.rawQuery(
        'SELECT SUM(leftover) AS total FROM employees_loans WHERE leftover > 0'));
    return (raw.first['total'] as num?)?.toDouble() ?? 0.0;
  }
}
