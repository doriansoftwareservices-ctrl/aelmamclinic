// lib/providers/statistics_provider.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/models/support_rating_entry.dart';
import 'package:aelmamclinic/services/support_ratings_service.dart';
import 'package:aelmamclinic/core/auth_role_state.dart';
import 'package:aelmamclinic/models/alert_setting.dart';
import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/consumption.dart';

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

  Timer? _pollTimer;
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

    // فحص احتياطي بطيء لتحديث الإحصاءات في حال عدم وصول تغييرات.
    _pollTimer ??= Timer.periodic(const Duration(seconds: 60), (_) async {
      if (_disposed) return;
      final db = DBService.instance;
      if (await db.isStatisticsDirty()) {
        await refresh();
        await db.clearStatisticsDirty();
      }
    });
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

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
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
  String get fmtFacilityConsumptions =>
      _currency.format(_monthlyFacilityConsumptions);
  String get fmtNetProfit => _currency.format(_monthlyNetProfit);
  String get fmtPatientsRemaining => _currency.format(_monthlyPatientsRemaining);
  String get fmtPendingLoans => _currency.format(_pendingLoans);

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

  DateTime _monthEnd(DateTime d) =>
      DateTime(d.year, d.month + 1, 0, 23, 59, 59);

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

  List<String> _monthLabels() {
    return List<String>.generate(12, (i) => (i + 1).toString().padLeft(2, '0'));
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

      final List<Patient> patients = await db.getAllPatients();
      Iterable<Patient> patientsFiltered = patients;
      if (start != null) {
        patientsFiltered = patientsFiltered.where((p) =>
            p.registerDate.isAfter(start.subtract(const Duration(days: 1))));
      }
      if (end != null) {
        patientsFiltered = patientsFiltered.where((p) =>
            p.registerDate.isBefore(end.add(const Duration(days: 1))));
      }

      final df = DateFormat('yyyy-MM-dd');
      final incomeByDate = <String, double>{};
      final incomeByDoctor = <String, double>{};
      for (final p in patientsFiltered) {
        final k = df.format(p.registerDate);
        incomeByDate[k] = (incomeByDate[k] ?? 0) + _safeNumber(p.paidAmount);

        final nameRaw = p.doctorName;
        final doc = (nameRaw == null || nameRaw.trim().isEmpty)
            ? 'الأشعة/المختبر'
            : nameRaw.trim();
        incomeByDoctor[doc] =
            (incomeByDoctor[doc] ?? 0) + _safeNumber(p.paidAmount);
      }

      final List<Consumption> consumptions = await db.getAllConsumption();
      Iterable<Consumption> consFiltered = consumptions;
      if (start != null) {
        consFiltered = consFiltered.where((c) =>
            c.date.isAfter(start.subtract(const Duration(days: 1))));
      }
      if (end != null) {
        consFiltered = consFiltered.where((c) =>
            c.date.isBefore(end.add(const Duration(days: 1))));
      }

      final consByDate = <String, double>{};
      final consByType = <String, double>{};
      for (final c in consFiltered) {
        final k = df.format(c.date);
        consByDate[k] = (consByDate[k] ?? 0) + _safeNumber(c.amount);
        final noteRaw = (c.note ?? '').trim();
        final type = noteRaw.isEmpty ? 'غير محدد' : noteRaw;
        consByType[type] = (consByType[type] ?? 0) + _safeNumber(c.amount);
      }

      final from = start ?? DateTime(2000);
      final to = end ?? DateTime(2100);
      final shareByDate = await db.getDoctorShareByDateBetween(from, to);
      final netByDate = await db.getNetProfitByDateBetween(from, to);
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
      final buckets = _monthBuckets(monthlyFrom, monthlyTo);
      final monthFmt = DateFormat('yyyy-MM');
      final incomeByMonth = <String, double>{};
      final consumptionByMonth = <String, double>{};
      final netByMonth = <String, double>{};

      for (final m in buckets) {
        final label = monthFmt.format(m);
        incomeByMonth[label] = 0.0;
        consumptionByMonth[label] = 0.0;
        netByMonth[label] = 0.0;
      }

      for (final p in patients) {
        final key = monthFmt.format(_monthStart(p.registerDate));
        if (incomeByMonth.containsKey(key)) {
          incomeByMonth[key] =
              (incomeByMonth[key] ?? 0) + _safeNumber(p.paidAmount);
        }
      }

      for (final c in consumptions) {
        final key = monthFmt.format(_monthStart(c.date));
        if (consumptionByMonth.containsKey(key)) {
          consumptionByMonth[key] =
              (consumptionByMonth[key] ?? 0) + _safeNumber(c.amount);
        }
      }

      for (final m in buckets) {
        final label = monthFmt.format(m);
        final monthStart = _monthStart(m);
        final monthEnd = _monthEnd(m);
        final map = await db.getNetProfitByDateBetween(monthStart, monthEnd);
        final sum = map.values.fold<double>(
          0.0,
          (s, v) => s + _safeNumber(v),
        );
        netByMonth[label] = sum;
      }

      // مقارنة سنوية (عامين)
      final months = _monthLabels();
      final incomeYearA = <String, double>{};
      final incomeYearB = <String, double>{};
      final netYearA = <String, double>{};
      final netYearB = <String, double>{};

      for (final m in months) {
        incomeYearA[m] = 0.0;
        incomeYearB[m] = 0.0;
        netYearA[m] = 0.0;
        netYearB[m] = 0.0;
      }

      for (final p in patients) {
        final y = p.registerDate.year;
        final m = p.registerDate.month.toString().padLeft(2, '0');
        if (y == _compareYearA && incomeYearA.containsKey(m)) {
          incomeYearA[m] =
              (incomeYearA[m] ?? 0) + _safeNumber(p.paidAmount);
        }
        if (y == _compareYearB && incomeYearB.containsKey(m)) {
          incomeYearB[m] =
              (incomeYearB[m] ?? 0) + _safeNumber(p.paidAmount);
        }
      }

      for (final month in months) {
        final m = int.parse(month);
        final startA = DateTime(_compareYearA, m, 1);
        final endA = _monthEnd(startA);
        final startB = DateTime(_compareYearB, m, 1);
        final endB = _monthEnd(startB);
        final mapA = await db.getNetProfitByDateBetween(startA, endA);
        final mapB = await db.getNetProfitByDateBetween(startB, endB);
        final sumA = mapA.values.fold<double>(
          0.0,
          (s, v) => s + _safeNumber(v),
        );
        final sumB = mapB.values.fold<double>(
          0.0,
          (s, v) => s + _safeNumber(v),
        );
        netYearA[month] = sumA;
        netYearB[month] = sumB;
      }

      // تحليل النمو والانخفاض
      final currentFrom = start ?? DateTime.now().subtract(const Duration(days: 30));
      final currentTo = end ?? DateTime.now();
      final periodDays = currentTo.difference(currentFrom).inDays.abs();
      final prevTo = currentFrom.subtract(const Duration(days: 1));
      final prevFrom = prevTo.subtract(Duration(days: periodDays));

      final currentIncome = incomeByDate.values.fold<double>(
        0.0,
        (s, v) => s + _safeNumber(v),
      );
      final prevIncome =
          _safeNumber(await db.getSumPatientsBetween(prevFrom, prevTo));

      final currentConsumption = consByDate.values.fold<double>(
        0.0,
        (s, v) => s + _safeNumber(v),
      );
      final prevConsumption =
          _safeNumber(await db.getSumConsumptionsBetween(prevFrom, prevTo));

      final currentNet = netByDate.values.fold<double>(
        0.0,
        (s, v) => s + _safeNumber(v),
      );
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
    } catch (_) {
      // Keep previous data on error
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
      final monthFmt = DateFormat('yyyy-MM');
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
