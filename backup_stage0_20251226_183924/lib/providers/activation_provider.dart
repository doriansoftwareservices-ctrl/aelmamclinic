import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ActivationProvider with ChangeNotifier {
  bool _isActivated = false;
  DateTime? _expiryDate;
  Timer? _expiryTimer;
  DateTime? _lastTimeCheck;

  /// المنشئ الافتراضي: يقوم بتحميل الحالة وتشغيل _init()
  ActivationProvider() {
    _init();
  }

  /// منشئ خاص: يستخدم بيانات مُحمّلة مسبقاً قبل runApp()
  ActivationProvider.withInitial({
    required bool isActivated,
    DateTime? expiryDate,
    DateTime? lastTimeCheck,
  }) {
    _isActivated = isActivated;
    _expiryDate = expiryDate;
    _lastTimeCheck = lastTimeCheck;
    _syncInitialState();
  }

  /// يزامن الحالة الأولية: يتعامل مع انتهاء الصلاحية والتلاعب بالوقت
  Future<void> _syncInitialState() async {
    final prefs = await SharedPreferences.getInstance();

    // اكتشاف الرجوع بالوقت
    if (_lastTimeCheck != null && DateTime.now().isBefore(_lastTimeCheck!)) {
      _isActivated = false;
      _expiryDate = null;
      await prefs.setBool('isActivated', false);
      await prefs.remove('expiryDate');
    }

    // اكتشاف التقدم المفرط بالوقت (تخطي أكثر من يوم)
    if (_lastTimeCheck != null) {
      final diff = DateTime.now().difference(_lastTimeCheck!);
      if (diff.inDays > 1) {
        _isActivated = false;
        _expiryDate = null;
        await prefs.setBool('isActivated', false);
        await prefs.remove('expiryDate');
      }
    }

    // اكتشاف انتهاء الصلاحية
    if (_expiryDate != null && DateTime.now().isAfter(_expiryDate!)) {
      _isActivated = false;
      _expiryDate = null;
      await prefs.setBool('isActivated', false);
      await prefs.remove('expiryDate');
    }

    // ضبط المؤقت إذا لا زال هناك صلاحية
    _setupExpiryTimer();

    // تحديث آخر تحقق
    await _updateLastTimeCheck();
    notifyListeners();
  }

  /// يحمّل حالة التفعيل من SharedPreferences ويتحقق من انتهاء الصلاحية والتلاعب بالوقت
  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _isActivated = prefs.getBool('isActivated') ?? false;
    final expiryString = prefs.getString('expiryDate');
    final lastCheckString = prefs.getString('lastTimeCheck');

    if (lastCheckString != null) {
      _lastTimeCheck = DateTime.parse(lastCheckString);

      // اكتشاف الرجوع بالوقت
      if (DateTime.now().isBefore(_lastTimeCheck!)) {
        await deactivate();
        return;
      }

      // اكتشاف التقدم المفرط بالوقت
      final diff = DateTime.now().difference(_lastTimeCheck!);
      if (diff.inDays > 1) {
        await deactivate();
        return;
      }
    }

    if (expiryString != null) {
      _expiryDate = DateTime.parse(expiryString);

      // التحقق من انتهاء الصلاحية
      if (DateTime.now().isAfter(_expiryDate!)) {
        await deactivate();
        return;
      }

      _setupExpiryTimer();
    }

    await _updateLastTimeCheck();
    notifyListeners();
  }

  bool get isActivated => _isActivated;
  DateTime? get expiryDate => _expiryDate;

  /// يفعّل التطبيق لعدد أيام محدد
  Future<void> activate(int days) async {
    final prefs = await SharedPreferences.getInstance();
    _expiryDate = DateTime.now().add(Duration(days: days));
    _isActivated = true;

    await prefs.setBool('isActivated', true);
    await prefs.setString('expiryDate', _expiryDate!.toIso8601String());

    await _updateLastTimeCheck();
    _setupExpiryTimer();
    notifyListeners();
  }

  /// يُلغي تفعيل التطبيق فوراً
  Future<void> deactivate() async {
    final prefs = await SharedPreferences.getInstance();
    _isActivated = false;
    _expiryDate = null;

    await prefs.setBool('isActivated', false);
    await prefs.remove('expiryDate');

    await _updateLastTimeCheck();
    _expiryTimer?.cancel();
    notifyListeners();
  }

  /// يحدث طابع آخر تحقق زمني
  Future<void> _updateLastTimeCheck() async {
    final prefs = await SharedPreferences.getInstance();
    _lastTimeCheck = DateTime.now();
    await prefs.setString(
      'lastTimeCheck',
      _lastTimeCheck!.toIso8601String(),
    );
  }

  /// يضبط مؤقت انتهاء الصلاحية
  void _setupExpiryTimer() {
    _expiryTimer?.cancel();
    if (_expiryDate == null) return;

    final duration = _expiryDate!.difference(DateTime.now());
    if (duration.isNegative) {
      unawaited(
        () async {
          try {
            await deactivate();
          } catch (error, stackTrace) {
            Zone.current.handleUncaughtError(error, stackTrace);
          }
        }(),
      );
      return;
    }

    _expiryTimer = Timer(duration, () {
      unawaited(
        () async {
          try {
            await deactivate();
          } catch (error, stackTrace) {
            Zone.current.handleUncaughtError(error, stackTrace);
          }
        }(),
      );
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }
}
