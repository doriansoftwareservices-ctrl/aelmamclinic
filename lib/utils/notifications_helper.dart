// lib/utils/notifications_helper.dart
//
// NotificationsHelper
// • تهيئة flutter_local_notifications مرة واحدة + مناطق الزمن (tz)
// • قناة Android ثابتة لتنبيهات انخفاض المخزون
// • طلب الأذونات (iOS/macOS/Android 13+)
// • showLowStock(Item) لإظهار إشعار فوري + تجميع Group على أندرويد
// • بثّ taps على الإشعار عبر Stream ليسهل التنقّل داخل التطبيق
// • دوال مساعدة: إلغاء إشعار صنف/إلغاء الكل
//
// ملاحظات:
// - احرص على استدعاء `await NotificationsHelper.instance.init();` مبكرًا (في main())
// - يمكن الاستماع لنقرات الإشعارات عبر:
//     NotificationsHelper.instance.onTap.listen((payload) { ... });
//
// - إن أردت جلب الـ payload كـ JSON:
//     final data = jsonDecode(payload) as Map<String, dynamic>;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'package:aelmamclinic/models/item.dart';
import 'package:aelmamclinic/utils/app_formatters.dart';
import 'package:aelmamclinic/utils/app_locale.dart';

class NotificationsHelper {
  NotificationsHelper._();
  static final NotificationsHelper instance = NotificationsHelper._();
  static const String _localePrefsKey = 'app.locale_code';
  static const String _lowStockChannelBaseId = 'low_stock_channel';

  final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();

  /// مفتاح تجميعي لإشعارات "انخفاض المخزون" على أندرويد
  static const String _lowStockGroupKey = 'group_low_stock';

  bool _initialized = false;
  String _languageCode = AppLocale.defaultLanguageCode;

  // بثّ نقرات الإشعارات (foreground/background)
  final StreamController<String> _tapCtrl =
      StreamController<String>.broadcast();
  Stream<String> get onTap => _tapCtrl.stream;

  String get _lowStockChannelId =>
      '${_lowStockChannelBaseId}_${AppLocale.normalize(_languageCode)}_v2';
  bool get _isArabic => AppLocale.isRtlCode(_languageCode);
  String get _lowStockChannelName =>
      _isArabic ? 'تنبيهات انخفاض المخزون' : 'Low stock alerts';
  String get _lowStockChannelDescription => _isArabic
      ? 'يتم استخدام هذه القناة لتنبيهك عندما يقترب مخزون صنف من النفاد.'
      : 'This channel is used to alert you when an item is running low.';
  String get _lowStockSummaryBody => _isArabic
      ? 'تم تنبيهك بخصوص أصناف منخفضة المخزون.'
      : 'You were alerted about items that are running low.';
  String get _lowStockExpandedBody => _isArabic
      ? 'تحذير انخفاض المخزون — راجع إدارة المستودع لتحديث الطلبية.'
      : 'Low stock warning — review repository management to update the order.';

  String _localizedStock(num stock) => AppFormatters.localizeDigits(
        '$stock',
        languageCode: _languageCode,
      );

  Future<void> _loadLanguageCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _languageCode = AppLocale.normalize(prefs.getString(_localePrefsKey));
    } catch (_) {
      _languageCode = AppLocale.defaultLanguageCode;
    }
  }

  Future<void> setLanguageCode(String languageCode) async {
    _languageCode = AppLocale.normalize(languageCode);
    if (_initialized && Platform.isAndroid) {
      await _createLowStockChannel();
    }
  }

  Future<void> _createLowStockChannel() async {
    if (!Platform.isAndroid) return;
    await _fln
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          AndroidNotificationChannel(
            _lowStockChannelId,
            _lowStockChannelName,
            description: _lowStockChannelDescription,
            importance: Importance.max,
          ),
        );
  }

  /* ─── التهيئة + طلب الأذونات ─── */
  Future<void> init() async {
    if (_initialized) return;
    await _loadLanguageCode();

    // مناطق الزمن
    tz.initializeTimeZones();
    try {
      final loc = tz.getLocation('Asia/Aden');
      tz.setLocalLocation(loc);
    } catch (_) {
      // تجاهل في حال عدم توفّر المنطقة
    }

    // إعدادات Android
    const initAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');

    // إعدادات iOS / macOS
    const initDarwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _fln.initialize(
      const InitializationSettings(
        android: initAndroid,
        iOS: initDarwin,
        macOS: initDarwin,
      ),
      onDidReceiveNotificationResponse: _onNotificationTap,
      // ملاحظة: يجب أن تكون دالة مستوى أعلى — عرفناها أسفل الملف.
      onDidReceiveBackgroundNotificationResponse: onNotificationTapBackground,
    );

    // إنشاء القناة (Android)
    await _createLowStockChannel();

    // اطلب أذونات النظام عند الحاجة (Android 13+ / iOS / macOS)
    await requestPermissions();

    _initialized = true;
  }

  /// يطلب أذونات الإشعارات (آمن النداء لمرات متعددة)
  Future<void> requestPermissions() async {
    // iOS
    await _fln
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    // macOS
    await _fln
        .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    // Android 13+
    await _fln
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /* ─── إشعار انخفاض المخزون ─── */

  /// الاسم الجديد: إظهار إشعار فوري لصنف منخفض المخزون
  Future<void> showLowStock(Item item) async {
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      try {
        SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
      return;
    }
    await init(); // تأكّد من التهيئة/الأذونات

    final (id, name, stock) = _extractItemInfo(item);

    final androidDetails = AndroidNotificationDetails(
      _lowStockChannelId,
      _lowStockChannelName,
      channelDescription: _lowStockChannelDescription,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      ticker: 'low_stock',
      groupKey: _lowStockGroupKey,
      styleInformation: BigTextStyleInformation(
        // نص طويل يظهر عند التوسيع
        _lowStockExpandedBody,
      ),
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final payload = jsonEncode({
      'type': 'low_stock',
      'itemId': id,
      'name': name,
      'stock': stock,
    });

    // إشعار الفرد
    await _fln.show(
      id, // notification id
      _isArabic ? '⚠️ $name أوشك على النفاد' : '⚠️ $name is running low',
      _isArabic
          ? 'المتبقي في المستودع: ${_localizedStock(stock)} وحدات فقط!'
          : 'Only ${_localizedStock(stock)} units remain in stock!',
      NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      ),
      payload: payload,
    );

    // إشعار تجميعي (Group Summary) — يحسّن العرض عند تعدّد الأصناف
    await _fln.show(
      0, // ثابت للـ summary
      _lowStockChannelName,
      _lowStockSummaryBody,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _lowStockChannelId,
          _lowStockChannelName,
          channelDescription: _lowStockChannelDescription,
          styleInformation: DefaultStyleInformation(true, true),
          groupKey: _lowStockGroupKey,
          setAsGroupSummary: true,
        ),
      ),
    );
  }

  /// (توافق عكسي) الاسم القديم الذي يستدعيه كودك الحالي.
  /// يبقى موجودًا لتجنّب كسر الشيفرة التي تنادي triggerLowStock().
  Future<void> triggerLowStock(Item item) => showLowStock(item);

  /* ─── إدارة الإلغاء ─── */

  /// إلغاء إشعار صنف محدّد
  Future<void> cancelForItem(Item item) async {
    final (notificationId, _, _) = _extractItemInfo(item);
    await _fln.cancel(notificationId);
  }

  /// إلغاء جميع الإشعارات
  Future<void> cancelAll() => _fln.cancelAll();

  /* ─── داخلي: التعامل مع الضغط على الإشعار ─── */

  void _onNotificationTap(NotificationResponse response) {
    if (response.payload != null) {
      _tapCtrl.add(response.payload!);
    }
  }

  /// يُستدعى من دالة المستوى الأعلى عند النقر في الخلفية.
  static void handleBackgroundTap(NotificationResponse response) {
    if (response.payload != null) {
      NotificationsHelper.instance._tapCtrl.add(response.payload!);
    }
  }

  /* ─── داخلي: استخراج بيانات الصنف ─── */
  (int id, String name, num stock) _extractItemInfo(Item item) {
    int id;
    final rawId = item.id;
    if (rawId is int) {
      id = rawId;
    } else {
      try {
        id = int.tryParse('$rawId') ?? item.hashCode;
      } catch (_) {
        id = item.hashCode;
      }
    }

    final name = item.name;
    final stock = item.stock;

    return (id, name, stock);
  }
}

/// دالة مستوى أعلى مطلوبة من flutter_local_notifications لاستقبال نقرات
/// الإشعارات في الخلفية (background/terminated).
@pragma('vm:entry-point')
void onNotificationTapBackground(NotificationResponse response) {
  NotificationsHelper.handleBackgroundTap(response);
}
