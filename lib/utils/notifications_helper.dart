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

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'package:aelmamclinic/models/item.dart';

class NotificationsHelper {
  NotificationsHelper._();
  static final NotificationsHelper instance = NotificationsHelper._();

  final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();

  /// قناة أندرويد لتنبيهات انخفاض المخزون
  static const AndroidNotificationChannel _lowStockChannel =
      AndroidNotificationChannel(
    'low_stock_channel',
    'تنبيهات انخفاض المخزون',
    description:
        'يتم استخدام هذه القناة لتنبيهك عندما يقترب مخزون صنف من النفاد.',
    importance: Importance.max,
  );

  /// مفتاح تجميعي لإشعارات "انخفاض المخزون" على أندرويد
  static const String _lowStockGroupKey = 'group_low_stock';

  bool _initialized = false;

  // بثّ نقرات الإشعارات (foreground/background)
  final StreamController<String> _tapCtrl =
      StreamController<String>.broadcast();
  Stream<String> get onTap => _tapCtrl.stream;

  /* ─── التهيئة + طلب الأذونات ─── */
  Future<void> init() async {
    if (_initialized) return;

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
    await _fln
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_lowStockChannel);

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
    await init(); // تأكّد من التهيئة/الأذونات

    final (id, name, stock) = _extractItemInfo(item);

    final androidDetails = AndroidNotificationDetails(
      _lowStockChannel.id,
      _lowStockChannel.name,
      channelDescription: _lowStockChannel.description,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      ticker: 'low_stock',
      groupKey: _lowStockGroupKey,
      styleInformation: const BigTextStyleInformation(
        // نص طويل يظهر عند التوسيع
        'تحذير انخفاض المخزون — راجع إدارة المستودع لتحديث الطلبية.',
      ),
    );

    const darwinDetails = DarwinNotificationDetails();

    final payload = jsonEncode({
      'type': 'low_stock',
      'itemId': id,
      'name': name,
      'stock': stock,
    });

    // إشعار الفرد
    await _fln.show(
      id, // notification id
      '⚠️ $name أوشك على النفاد',
      'المتبقي في المستودع: $stock وحدات فقط!',
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
      'تنبيهات انخفاض المخزون',
      'تم تنبيهك بخصوص أصناف منخفضة المخزون.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'low_stock_channel',
          'تنبيهات انخفاض المخزون',
          channelDescription:
              'يتم استخدام هذه القناة لتنبيهك عندما يقترب مخزون صنف من النفاد.',
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
