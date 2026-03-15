// lib/providers/statistics_provider.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/models/support_rating_entry.dart';
import 'package:aelmamclinic/services/support_ratings_service.dart';
import 'package:aelmamclinic/core/auth_role_state.dart';
import 'package:aelmamclinic/models/alert_setting.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/phase8/statistics_redesign.dart';
import 'package:aelmamclinic/utils/app_observability.dart';

/// يجمع إحصاءات حيّة لتعبئة بطاقات Hero في لوحة الإحصاءات.
class StatisticsProvider extends ChangeNotifier {
  StatisticsProvider() {
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    _chartsFrom = DateTime(now.year, now.month, 1);
    _chartsTo = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    _startListeners();
    refresh();
  }

  Timer? _dirtyCheckTimer;
  Timer? _refreshDebounce;
  Timer? _chartsDebounce;
  StreamSubscription<String>? _dbChangesSub;
  bool _disposed = false;
  bool _autoRangeApplied = false;
  bool _chartsActive = false;

  static const Set<String> _statsTables = {
    'patients',
    'returns',
    'consumptions',
    'prescriptions',
    'prescription_items',
    'appointments',
    'doctors',
    'medical_services',
    'service_doctor_share',
    'employees_loans',
    'employees_discounts',
    'employees_salaries',
    'financial_logs',
    'patient_services',
    'items',
    'item_types',
    'alert_settings',
  };

  void _startListeners() {
    _dbChangesSub ??= DBService.instance.changes.listen((table) {
      if (_disposed) return;
      if (!_statsTables.contains(table)) return;
      _scheduleRefresh();
      if (_chartsActive) {
        _scheduleChartsRefresh();
      }
    });

    _scheduleDirtyCheck();
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), () {
      refresh();
    });
  }

  void _scheduleChartsRefresh() {
    _chartsDebounce?.cancel();
    _chartsDebounce = Timer(const Duration(milliseconds: 400), () {
      refreshCharts();
    });
  }

  void _scheduleDirtyCheck({
    Duration delay = const Duration(seconds: 60),
  }) {
    _dirtyCheckTimer?.cancel();
    _dirtyCheckTimer = Timer(delay, () async {
      if (_disposed) return;
      final db = DBService.instance;
      try {
        if (await db.isStatisticsDirty()) {
          await refresh();
          await db.clearStatisticsDirty();
        }
      } catch (e, st) {
        AppObservability.warn(
          scope: 'STATS',
          code: ObsCode.statsDirtyCheckFailed,
          message: 'statistics dirty-check refresh failed',
          flowId: AppObservability.newFlowId('stats_dirty_check'),
          error: e,
          stackTrace: st,
        );
      } finally {
        if (!_disposed) {
          _scheduleDirtyCheck();
        }
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _dirtyCheckTimer?.cancel();
    _refreshDebounce?.cancel();
    _chartsDebounce?.cancel();
    _dbChangesSub?.cancel();
    super.dispose();
  }

  late DateTime _from;
  late DateTime _to;
  DateTime? _chartsFrom;
  DateTime? _chartsTo;
  DateTime _doctorOutstandingAsOf = DateTime.now();

  DateTime get from => _from;
  DateTime get to => _to;
  DateTime? get chartsFrom => _chartsFrom;
  DateTime? get chartsTo => _chartsTo;
  DateTime get doctorOutstandingAsOf => _doctorOutstandingAsOf;

  void setRange({required DateTime from, required DateTime to}) {
    _from = DateTime(from.year, from.month, from.day);
    _to = DateTime(to.year, to.month, to.day, 23, 59, 59);
    refresh();
  }

  void setChartsActive(bool active) {
    _chartsActive = active;
  }

  void setChartsRange({DateTime? from, DateTime? to}) {
    _chartsFrom =
        from == null ? null : DateTime(from.year, from.month, from.day);
    _chartsTo =
        to == null ? null : DateTime(to.year, to.month, to.day, 23, 59, 59);
    if (_chartsActive) {
      refreshCharts();
    }
  }

  void setDoctorOutstandingAsOf(DateTime asOf) {
    _doctorOutstandingAsOf = asOf;
    if (_chartsActive) {
      refreshCharts();
    }
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
  double _monthlyFacilityConsumptions = 0.0;
  double _monthlyNetProfit = 0.0;
  double _monthlyPatientsRemaining = 0.0;

  int _monthlyPatients = 0;
  int _lowStockCount = 0;
  int _todayConfirmed = 0;
  int _todayFollowUps = 0;
  int _totalPatientsAll = 0;
  int _outOfStockItems = 0;
  double _pendingLoans = 0.0;

  bool _busy = false;
  bool _chartsBusy = false;

  // ───── getters ─────
  double get monthlyRevenue => _monthlyRevenue;
  double get monthlyExpense => _monthlyExpense;
  double get monthlyDoctorRatios => _monthlyDoctorRatios;
  double get monthlyDoctorInputs => _monthlyDoctorInputs;
  double get monthlyTowerShare => _monthlyTowerShare;
  double get monthlyLoansPaid => _monthlyLoansPaid;
  double get monthlyDiscounts => _monthlyDiscounts;
  double get monthlySalariesPaid => _monthlySalariesPaid;
  double get monthlyFacilityConsumptions => _monthlyFacilityConsumptions;
  double get monthlyNetProfit => _monthlyNetProfit;
  double get monthlyPatientsRemaining => _monthlyPatientsRemaining;

  int get monthlyPatients => _monthlyPatients;
  int get lowStockCount => _lowStockCount;
  int get todayConfirmed => _todayConfirmed;
  int get todayFollowUps => _todayFollowUps;
  int get totalPatientsAll => _totalPatientsAll;
  int get outOfStockItems => _outOfStockItems;
  double get pendingLoans => _pendingLoans;

  bool get busy => _busy;
  bool get chartsBusy => _chartsBusy;

  Map<String, double> _incomeByDate = {};
  Map<String, double> _consumptionByDate = {};
  Map<String, double> _incomeByDoctor = {};
  Map<String, double> _consumptionByType = {};
  Map<String, double> _doctorShareByDate = {};
  Map<String, double> _netProfitByDate = {};
  List<Map<String, dynamic>> _doctorOutstandingRows = [];
  Map<String, double> _monthlyIncome = {};
  Map<String, double> _monthlyConsumption = {};
  Map<String, double> _monthlyNetProfitSeries = {};
  int _compareYearA = DateTime.now().year - 1;
  int _compareYearB = DateTime.now().year;
  Map<String, double> _yearIncomeA = {};
  Map<String, double> _yearIncomeB = {};
  Map<String, double> _yearNetA = {};
  Map<String, double> _yearNetB = {};
  Map<String, double> _incomeForecast = {};
  Map<String, double> _consumptionForecast = {};
  Map<String, double> _netForecast = {};
  double _incomeGrowthPct = 0.0;
  double _consumptionGrowthPct = 0.0;
  double _netGrowthPct = 0.0;
  String _incomeTrend = 'ثابت';
  String _consumptionTrend = 'ثابت';
  String _netTrend = 'ثابت';

  List<SupportRatingEntry> _supportRatings = [];
  double _supportRatingAvg = 0.0;
  int _supportRatingsCount = 0;
  double _supportSatisfactionPct = 0.0;
  Map<String, int> _supportStarsCount = {};
  Map<String, double> _supportMonthlyAvg = {};
  Map<String, int> _supportMonthlyCount = {};

  Map<String, double> get incomeByDate => _incomeByDate;
  Map<String, double> get consumptionByDate => _consumptionByDate;
  Map<String, double> get incomeByDoctor => _incomeByDoctor;
  Map<String, double> get consumptionByType => _consumptionByType;
  Map<String, double> get doctorShareByDate => _doctorShareByDate;
  Map<String, double> get netProfitByDate => _netProfitByDate;
  List<Map<String, dynamic>> get doctorOutstandingRows =>
      List.unmodifiable(_doctorOutstandingRows);
  Map<String, double> get monthlyIncome => _monthlyIncome;
  Map<String, double> get monthlyConsumption => _monthlyConsumption;
  Map<String, double> get monthlyNetProfitSeries => _monthlyNetProfitSeries;
  int get compareYearA => _compareYearA;
  int get compareYearB => _compareYearB;
  Map<String, double> get yearIncomeA => _yearIncomeA;
  Map<String, double> get yearIncomeB => _yearIncomeB;
  Map<String, double> get yearNetA => _yearNetA;
  Map<String, double> get yearNetB => _yearNetB;
  Map<String, double> get incomeForecast => _incomeForecast;
  Map<String, double> get consumptionForecast => _consumptionForecast;
  Map<String, double> get netForecast => _netForecast;
  double get incomeGrowthPct => _incomeGrowthPct;
  double get consumptionGrowthPct => _consumptionGrowthPct;
  double get netGrowthPct => _netGrowthPct;
  String get incomeTrend => _incomeTrend;
  String get consumptionTrend => _consumptionTrend;
  String get netTrend => _netTrend;

  List<SupportRatingEntry> get supportRatings =>
      List.unmodifiable(_supportRatings);
  double get supportRatingAvg => _supportRatingAvg;
  int get supportRatingsCount => _supportRatingsCount;
  double get supportSatisfactionPct => _supportSatisfactionPct;
  Map<String, int> get supportStarsCount => _supportStarsCount;
  Map<String, double> get supportMonthlyAvg => _supportMonthlyAvg;
  Map<String, int> get supportMonthlyCount => _supportMonthlyCount;

  String get fmtRevenue =>
      AppFormatters.formatCurrency(_monthlyRevenue, decimalDigits: 0);
  String get fmtExpense =>
      AppFormatters.formatCurrency(_monthlyExpense, decimalDigits: 0);
  String get fmtDoctorRatios =>
      AppFormatters.formatCurrency(_monthlyDoctorRatios, decimalDigits: 0);
  String get fmtDoctorInputs =>
      AppFormatters.formatCurrency(_monthlyDoctorInputs, decimalDigits: 0);
  String get fmtTowerShare =>
      AppFormatters.formatCurrency(_monthlyTowerShare, decimalDigits: 0);
  String get fmtLoansPaid =>
      AppFormatters.formatCurrency(_monthlyLoansPaid, decimalDigits: 0);
  String get fmtDiscounts =>
      AppFormatters.formatCurrency(_monthlyDiscounts, decimalDigits: 0);
  String get fmtSalariesPaid =>
      AppFormatters.formatCurrency(_monthlySalariesPaid, decimalDigits: 0);
  String get fmtFacilityConsumptions =>
      AppFormatters.formatCurrency(_monthlyFacilityConsumptions, decimalDigits: 0);
  String get fmtNetProfit =>
      AppFormatters.formatCurrency(_monthlyNetProfit, decimalDigits: 0);
  String get fmtPatientsRemaining =>
      AppFormatters.formatCurrency(_monthlyPatientsRemaining, decimalDigits: 0);
  String get fmtPendingLoans =>
      AppFormatters.formatCurrency(_pendingLoans, decimalDigits: 0);

  /// تحميل / تحديث جميع الإحصاءات
  Future<void> refresh() async {
    if (_disposed) return;
    if (_busy) return;
    _busy = true;
    if (!_disposed) {
      notifyListeners();
    }

    try {
      final db = DBService.instance;

      // 1) إيرادات الفترة (تحصيل فعلي، مع fallback للخدمات للأنظمة القديمة)
      final revenue = await db.getIncomeTotalBetween(_from, _to);
      // 2) مشتريات المستودع (تُحسب عند الشراء)
      final expense = await db.getSumPurchasesBetween(_from, _to);
      // 3) نسب الأطباء
      final ratios = await db.getSumAllDoctorShareBetween(_from, _to);
      // 4) مدخلات الأطباء بعد خصم المركز
      final inputs = await db.getEffectiveSumAllDoctorInputBetween(_from, _to);
      // 5) حصّة المركز
      final tower = await db.getSumAllTowerShareBetween(_from, _to);
      // 6) سلف مصروفة
      final loansRaw = await db.database.then((d) => d.rawQuery(
          'SELECT SUM(loanAmount) AS total FROM employees_loans '
          'WHERE loanDateTime BETWEEN ? AND ? '
          'AND ifnull(isSettled,0)=0 '
          'AND ifnull(isDeleted,0)=0',
          [_from.toIso8601String(), _to.toIso8601String()]));
      final loans = (loansRaw.first['total'] as num?)?.toDouble() ?? 0.0;
      // 7) خصومات
      final discRaw = await db.database.then((d) => d.rawQuery(
          'SELECT SUM(amount) AS total FROM employees_discounts WHERE discountDateTime BETWEEN ? AND ? AND ifnull(isDeleted,0)=0',
          [_from.toIso8601String(), _to.toIso8601String()]));
      final discounts = (discRaw.first['total'] as num?)?.toDouble() ?? 0.0;
      // 8) رواتب
      final salRaw = await db.database.then((d) => d.rawQuery(
          'SELECT SUM(netPay) AS total FROM employees_salaries WHERE paymentDate BETWEEN ? AND ? AND ifnull(isDeleted,0)=0',
          [_from.toIso8601String(), _to.toIso8601String()]));
      final salaries = (salRaw.first['total'] as num?)?.toDouble() ?? 0.0;
      // 9) استهلاكات المرفق الصحي
      final facilityConsumptions =
          await db.getSumConsumptionsBetween(_from, _to);
      // صافي الربح
      final netProfit = await db.getNetProfitTotalBetween(_from, _to);
      // المبالغ المتبقية على المرضى
      final remainingPatients =
          await db.getSumPatientsRemainingBetween(_from, _to);

      // 9) تعداد المرضى
      final monthlyPts = await _countPatientsBetween(_from, _to);
      // 10) تنبيهات المخزون المنخفض
      final lowStock = await _getLowStockCount();
      // 11) عودات اليوم (مؤكدة/أتت اليوم) من الخادم عبر المزامنة
      final allReturns = await db.getAllReturns();
      final now = DateTime.now();
      bool sameDay(DateTime a, DateTime b) =>
          a.year == b.year && a.month == b.month && a.day == b.day;
      final todayReturns = allReturns.where((r) => sameDay(r.date, now)).toList();
      final todayConf = todayReturns.length;
      final todayFoll = todayReturns.where((r) => r.isAttended).length;

      // 13) بيانات إضافية
      final totalPts = await db.getTotalPatients();
      final outOfStock = await _getOutOfStockCount();
      final pendLoans = await _getPendingLoansSum();

      // إذا كانت الفترة الحالية فارغة لكن توجد بيانات فعلية:
      // اضبط الفترة تلقائيًا لتشمل أقدم بيانات محلية (مرة واحدة فقط).
      if (!_autoRangeApplied &&
          totalPts > 0 &&
          monthlyPts == 0 &&
          _from.isAfter(_to)) {
        // لا شيء
      }
      if (!_autoRangeApplied &&
          totalPts > 0 &&
          monthlyPts == 0 &&
          revenue == 0 &&
          expense == 0 &&
          facilityConsumptions == 0) {
        final suggested = await _suggestFromDate();
        if (suggested != null) {
          _autoRangeApplied = true;
          _from = DateTime(suggested.year, suggested.month, suggested.day);
          _to = DateTime.now();
          _busy = false;
          if (!_disposed) notifyListeners();
          await refresh();
          return;
        }
      }

      if (_disposed) return;

      // تخزين القيم
      _monthlyRevenue = revenue;
      _monthlyExpense = expense;
      _monthlyDoctorRatios = ratios;
      _monthlyDoctorInputs = inputs;
      _monthlyTowerShare = tower;
      _monthlyLoansPaid = loans;
      _monthlyDiscounts = discounts;
      _monthlySalariesPaid = salaries;
      _monthlyFacilityConsumptions = facilityConsumptions;
      _monthlyNetProfit = netProfit;
      _monthlyPatientsRemaining = remainingPatients;

      _monthlyPatients = monthlyPts;
      _lowStockCount = lowStock;
      _todayConfirmed = todayConf;
      _todayFollowUps = todayFoll;

      _totalPatientsAll = totalPts;
      _outOfStockItems = outOfStock;
      _pendingLoans = pendLoans;
    } finally {
      _busy = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
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

  double _safeNumber(double value) {
    if (value.isNaN || value.isInfinite) return 0;
    return value;
  }

  String _trendLabel(double pct) {
    if (pct > 0.5) return 'ارتفاع';
    if (pct < -0.5) return 'انخفاض';
    return 'ثابت';
  }

  double _pctChange(double current, double previous) {
    if (previous == 0) {
      if (current == 0) return 0;
      return 100;
    }
    return ((current - previous) / previous) * 100.0;
  }

  DateTime _monthStart(DateTime d) => DateTime(d.year, d.month, 1);

  List<DateTime> _monthBuckets(DateTime from, DateTime to) {
    final start = _monthStart(from);
    final end = _monthStart(to);
    final buckets = <DateTime>[];
    var cursor = start;
    while (!cursor.isAfter(end)) {
      buckets.add(cursor);
      cursor = DateTime(cursor.year, cursor.month + 1, 1);
    }
    return buckets;
  }

  Map<String, double> _linearForecast(
    Map<String, double> monthlyMap, {
    int lookback = 6,
    int horizon = 3,
  }) {
    final entries = monthlyMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) return {};

    final recent = entries.length <= lookback
        ? entries
        : entries.sublist(entries.length - lookback);
    if (recent.length < 2) return {};

    final xs = List<double>.generate(recent.length, (i) => i.toDouble());
    final ys = recent.map((e) => _safeNumber(e.value)).toList();

    final n = xs.length;
    final sumX = xs.reduce((a, b) => a + b);
    final sumY = ys.reduce((a, b) => a + b);
    final sumXY = List<double>.generate(n, (i) => xs[i] * ys[i])
        .reduce((a, b) => a + b);
    final sumX2 =
        xs.map((x) => x * x).reduce((a, b) => a + b);

    final denom = (n * sumX2 - sumX * sumX);
    final slope = denom == 0 ? 0 : (n * sumXY - sumX * sumY) / denom;
    final intercept = (sumY - slope * sumX) / n;

    final lastKey = entries.last.key;
    final lastDate = DateTime.tryParse('$lastKey-01');
    if (lastDate == null) return {};

    final forecast = <String, double>{};
    for (var i = 1; i <= horizon; i++) {
      final idx = (recent.length - 1 + i).toDouble();
      final value = _safeNumber(intercept + slope * idx);
      final d = DateTime(lastDate.year, lastDate.month + i, 1);
      final label = DateFormat('yyyy-MM').format(d);
      forecast[label] = value < 0 ? 0 : value;
    }
    return forecast;
  }

  Future<void> refreshCharts() async {
    if (_disposed) return;
    if (_chartsBusy) return;
    _chartsBusy = true;
    if (!_disposed) {
      notifyListeners();
    }

    try {
      final db = DBService.instance;
      final range = _normalizedRange(_chartsFrom, _chartsTo);
      final start = range.start;
      final end = range.end;
      final from = start ?? DateTime(2000);
      final to = end ?? DateTime(2100);

      final results = await Future.wait<Object>([
        db.getIncomeByDateBetween(from, to),
        db.getPatientPaymentsByDoctorBetween(from, to),
        db.getConsumptionByDateBetween(from, to),
        db.getConsumptionByTypeBetween(from, to),
        db.getDoctorShareByDateBetween(from, to),
        db.getNetProfitByDateBetween(from, to),
      ]);

      final incomeByDate = Map<String, double>.from(
        results[0] as Map<String, double>,
      );
      final incomeByDoctor = Map<String, double>.from(
        results[1] as Map<String, double>,
      );
      final consByDate = Map<String, double>.from(
        results[2] as Map<String, double>,
      );
      final consByType = Map<String, double>.from(
        results[3] as Map<String, double>,
      );
      final shareByDate = Map<String, double>.from(
        results[4] as Map<String, double>,
      );
      final netByDate = Map<String, double>.from(
        results[5] as Map<String, double>,
      );
      final outstanding =
          await db.getDoctorOutstandingBalances(asOf: _doctorOutstandingAsOf);

      // مقارنة شهرية (آخر 6 أشهر أو ضمن النطاق المحدد)
      DateTime monthlyFrom;
      DateTime monthlyTo;
      if (start != null && end != null) {
        monthlyFrom = _monthStart(start);
        monthlyTo = _monthStart(end);
      } else {
        final now = DateTime.now();
        monthlyTo = _monthStart(now);
        monthlyFrom = DateTime(now.year, now.month - 5, 1);
      }
      final incomeByMonth = rollupDailySeriesToMonthly(
        incomeByDate,
        from: monthlyFrom,
        to: monthlyTo,
      );
      final consumptionByMonth = rollupDailySeriesToMonthly(
        consByDate,
        from: monthlyFrom,
        to: monthlyTo,
      );
      final netByMonth = rollupDailySeriesToMonthly(
        netByDate,
        from: monthlyFrom,
        to: monthlyTo,
      );

      // مقارنة سنوية (عامين)
      final yearStartA = DateTime(_compareYearA, 1, 1);
      final yearEndA = DateTime(_compareYearA, 12, 31, 23, 59, 59);
      final yearStartB = DateTime(_compareYearB, 1, 1);
      final yearEndB = DateTime(_compareYearB, 12, 31, 23, 59, 59);

      final yearResults = await Future.wait<Object>([
        db.getIncomeByDateBetween(yearStartA, yearEndA),
        db.getIncomeByDateBetween(yearStartB, yearEndB),
        db.getNetProfitByDateBetween(yearStartA, yearEndA),
        db.getNetProfitByDateBetween(yearStartB, yearEndB),
      ]);

      final incomeYearA = buildYearMonthlySeries(
        Map<String, double>.from(yearResults[0] as Map<String, double>),
        year: _compareYearA,
      );
      final incomeYearB = buildYearMonthlySeries(
        Map<String, double>.from(yearResults[1] as Map<String, double>),
        year: _compareYearB,
      );
      final netYearA = buildYearMonthlySeries(
        Map<String, double>.from(yearResults[2] as Map<String, double>),
        year: _compareYearA,
      );
      final netYearB = buildYearMonthlySeries(
        Map<String, double>.from(yearResults[3] as Map<String, double>),
        year: _compareYearB,
      );

      // تحليل النمو والانخفاض
      final currentFrom = start ?? DateTime.now().subtract(const Duration(days: 30));
      final currentTo = end ?? DateTime.now();
      final periodDays = currentTo.difference(currentFrom).inDays.abs();
      final prevTo = currentFrom.subtract(const Duration(days: 1));
      final prevFrom = prevTo.subtract(Duration(days: periodDays));

      final currentIncome = sumSeries(incomeByDate);
      final prevIncome =
          _safeNumber(await db.getSumPatientsBetween(prevFrom, prevTo));

      final currentConsumption = sumSeries(consByDate);
      final prevConsumption =
          _safeNumber(await db.getSumConsumptionsBetween(prevFrom, prevTo));

      final currentNet = sumSeries(netByDate);
      final prevNet =
          _safeNumber(await db.getNetProfitTotalBetween(prevFrom, prevTo));

      final incomePct = _pctChange(currentIncome, prevIncome);
      final consumptionPct = _pctChange(currentConsumption, prevConsumption);
      final netPct = _pctChange(currentNet, prevNet);

      _incomeByDate = incomeByDate;
      _incomeByDoctor = incomeByDoctor;
      _consumptionByDate = consByDate;
      _consumptionByType = consByType;
      _doctorShareByDate = shareByDate;
      _netProfitByDate = netByDate;
      _doctorOutstandingRows = outstanding;
      _monthlyIncome = incomeByMonth;
      _monthlyConsumption = consumptionByMonth;
      _monthlyNetProfitSeries = netByMonth;
      _yearIncomeA = incomeYearA;
      _yearIncomeB = incomeYearB;
      _yearNetA = netYearA;
      _yearNetB = netYearB;
      _incomeGrowthPct = incomePct;
      _consumptionGrowthPct = consumptionPct;
      _netGrowthPct = netPct;
      _incomeTrend = _trendLabel(incomePct);
      _consumptionTrend = _trendLabel(consumptionPct);
      _netTrend = _trendLabel(netPct);
      _incomeForecast = _linearForecast(incomeByMonth);
      _consumptionForecast = _linearForecast(consumptionByMonth);
      _netForecast = _linearForecast(netByMonth);

      await _refreshSupportRatings(range.start, range.end);
    } catch (e, st) {
      AppObservability.warn(
        scope: 'STATS',
        code: ObsCode.statsChartsRefreshFailed,
        message: 'statistics charts refresh failed',
        flowId: AppObservability.newFlowId('stats_refresh_charts'),
        error: e,
        stackTrace: st,
      );
    } finally {
      _chartsBusy = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> _refreshSupportRatings(DateTime? start, DateTime? end) async {
    if (!AuthRoleState.isSuperAdmin) {
      _supportRatings = [];
      _supportRatingAvg = 0.0;
      _supportRatingsCount = 0;
      _supportSatisfactionPct = 0.0;
      _supportStarsCount = {};
      _supportMonthlyAvg = {};
      _supportMonthlyCount = {};
      return;
    }
    try {
      DateTime? from = start;
      DateTime? to = end;
      if (from == null || to == null) {
        final now = DateTime.now();
        to = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
        from = DateTime(now.year, now.month - 11, 1);
      }

      final accountId = await ActiveAccountStore.readAccountId();
      final ratings = await SupportRatingsService.instance.fetchRatings(
        from: from,
        to: to,
        accountId: accountId,
      );

      final total = ratings.length;
      final sum = ratings.fold<double>(0.0, (s, r) => s + r.rating);
      final avg = total == 0 ? 0.0 : sum / total;

      final stars = <String, int>{
        '1': 0,
        '2': 0,
        '3': 0,
        '4': 0,
        '5': 0,
      };
      int happy = 0;
      for (final r in ratings) {
        final key = r.rating.clamp(1, 5).toString();
        stars[key] = (stars[key] ?? 0) + 1;
        if (r.rating >= 4) happy++;
      }

      final buckets = _monthBuckets(
        DateTime(from.year, from.month, 1),
        DateTime(to.year, to.month, 1),
      );
      final monthFmt = AppFormatters.dateFormat('yyyy-MM');
      final monthlySum = <String, double>{};
      final monthlyCount = <String, int>{};
      for (final m in buckets) {
        final label = monthFmt.format(m);
        monthlySum[label] = 0.0;
        monthlyCount[label] = 0;
      }
      for (final r in ratings) {
        final label = monthFmt.format(DateTime(r.submittedAt.year, r.submittedAt.month, 1));
        if (!monthlySum.containsKey(label)) {
          monthlySum[label] = 0.0;
          monthlyCount[label] = 0;
        }
        monthlySum[label] = (monthlySum[label] ?? 0) + r.rating.toDouble();
        monthlyCount[label] = (monthlyCount[label] ?? 0) + 1;
      }

      final monthlyAvg = <String, double>{};
      for (final entry in monthlySum.entries) {
        final c = monthlyCount[entry.key] ?? 0;
        monthlyAvg[entry.key] = c == 0 ? 0.0 : (entry.value / c);
      }

      _supportRatings = ratings;
      _supportRatingsCount = total;
      _supportRatingAvg = avg;
      _supportSatisfactionPct =
          total == 0 ? 0.0 : (happy / total) * 100.0;
      _supportStarsCount = stars;
      _supportMonthlyAvg = monthlyAvg;
      _supportMonthlyCount = monthlyCount;
    } catch (_) {
      // keep previous values
    }
  }

  Future<DateTime?> _suggestFromDate() async {
    try {
      final db = await DBService.instance.database;
      final dates = <DateTime>[];
      DateTime? parseAny(Object? raw) {
        final s = raw?.toString().trim() ?? '';
        if (s.isEmpty) return null;
        return DateTime.tryParse(s);
      }

      // patients.registerDate
      final p = await db.rawQuery(
        'SELECT MIN(registerDate) AS v FROM patients WHERE ifnull(isDeleted,0)=0',
      );
      dates.add(parseAny(p.first['v']) ?? DateTime(2100));

      // consumptions.date
      final c = await db.rawQuery(
        'SELECT MIN(date) AS v FROM consumptions WHERE ifnull(isDeleted,0)=0',
      );
      dates.add(parseAny(c.first['v']) ?? DateTime(2100));

      // purchases.created_at
      final pu = await db.rawQuery(
        'SELECT MIN(created_at) AS v FROM purchases WHERE ifnull(isDeleted,0)=0',
      );
      dates.add(parseAny(pu.first['v']) ?? DateTime(2100));

      dates.removeWhere((d) => d.year >= 2099);
      if (dates.isEmpty) return null;
      dates.sort();
      return dates.first;
    } catch (_) {
      return null;
    }
  }

  Future<int> _getLowStockCount() async {
    final sql = '''
      SELECT COUNT(*) AS cnt
        FROM ${AlertSetting.table} AS a
        JOIN ${Item.table}         AS i ON i.id = a.item_id
       WHERE a.is_enabled = 1
         AND i.stock      <= a.threshold
         AND ifnull(a.isDeleted,0)=0
         AND ifnull(i.isDeleted,0)=0
    ''';
    final raw =
        await DBService.instance.database.then((db) => db.rawQuery(sql));
    return raw.isEmpty ? 0 : (raw.first['cnt'] as int? ?? 0);
  }

  Future<int> _countPatientsBetween(DateTime f, DateTime t) async {
    final raw = await DBService.instance.database.then((db) => db.rawQuery(
          'SELECT COUNT(*) AS cnt FROM patients WHERE registerDate BETWEEN ? AND ? AND ifnull(isDeleted,0)=0',
          [f.toIso8601String(), t.toIso8601String()],
        ));
    return raw.isEmpty ? 0 : (raw.first['cnt'] as int? ?? 0);
  }

  Future<int> _getOutOfStockCount() async {
    final raw = await DBService.instance.database.then((db) => db.rawQuery(
          'SELECT COUNT(*) AS cnt FROM ${Item.table} WHERE stock = 0 AND ifnull(isDeleted,0)=0',
        ));
    return raw.isEmpty ? 0 : (raw.first['cnt'] as int? ?? 0);
  }

  Future<double> _getPendingLoansSum() async {
    final raw = await DBService.instance.database.then((db) => db.rawQuery(
        'SELECT SUM(leftover) AS total FROM employees_loans WHERE leftover > 0'));
    return (raw.first['total'] as num?)?.toDouble() ?? 0.0;
  }
}
