// lib/services/notification_service.dart
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aelmamclinic/utils/app_error_reporter.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// معالج النقر على الإشعار (مستوى أعلى خارج الكلاس لتجنّب أخطاء Dart)
typedef NotificationTapHandler = Future<void> Function(
  String? payload,
  NotificationResponse response,
);

/// ⚠️ يجب أن يكون Top-level ومعلم بـ @pragma ليعمل في الخلفية/حالة الإنهاء.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  // نفوِّض نفس منطق المعالج الأساسي
  // (يمكن أن يكون async، لكن void تكفي هنا)
  NotificationService._onSelectNotification(response);
}

class NotificationService {
  // -------- Singleton آمن --------
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // -------- تكامل الملاحة (للـ deep-link إلى شاشة الدردشة) --------
  static GlobalKey<NavigatorState>? _navigatorKey;
  static String _chatRouteName = '/chat/room';

  static void attachNavigator(
    GlobalKey<NavigatorState> key, {
    String chatRouteName = '/chat/room',
  }) {
    _navigatorKey = key;
    _chatRouteName = chatRouteName;
  }

  static NotificationTapHandler? _externalTapHandler;
  static void setOnNotificationTap(NotificationTapHandler handler) {
    _externalTapHandler = handler;
  }

  // -------- القنوات/المحرّك --------
  final FlutterLocalNotificationsPlugin _flnp =
      FlutterLocalNotificationsPlugin();

  static const String _messagesChannelId = 'messages_channel_id';
  static const String _messagesChannelName = 'رسائل الدردشة';
  static const String _messagesChannelDesc =
      'إشعارات رسائل الدردشة مع صوت مخصص';

  static const String _returnsChannelId = 'returns_channel_id';
  static const String _returnsChannelName = 'تذكير العودات';
  static const String _returnsChannelDesc = 'إشعارات تذكير بمواعيد العودات';

  static const String _patientsChannelId = 'patients_channel_id';
  static const String _patientsChannelName = 'تنبيهات المرضى';
  static const String _patientsChannelDesc =
      'إشعارات الحالات المرضية الجديدة للأطباء';

  static const String _adminChannelId = 'admin_channel_id';
  static const String _adminChannelName = 'تنبيهات الإدارة';
  static const String _adminChannelDesc =
      'إشعارات طلبات الترقية ورسائل خدمة العملاء';

  static const String _kBatteryOptPrompted = 'notif.battery_opt_prompted';

  bool _initialized = false;
  bool get isReady => _initialized;

  bool _tzReady = false;
  Future<void>? _initFuture;
  final Map<int, Timer> _winScheduled = <int, Timer>{};

  bool get _supportedPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  bool get _isWindows => !kIsWeb && Platform.isWindows;

  void _showInAppFallback({
    required String title,
    required String body,
  }) {
    final t = title.trim();
    final b = body.trim();
    if (t.isEmpty && b.isEmpty) return;
    final message = b.isEmpty ? t : '$t\n$b';
    AppErrorReporter.info(message);
  }

  Future<void> promptBatteryOptimizationIfNeeded() async {
    if (kIsWeb || !Platform.isAndroid) return;
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool(_kBatteryOptPrompted) == true) return;

    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) {
      await sp.setBool(_kBatteryOptPrompted, true);
      return;
    }

    final ctx = _navigatorKey?.currentContext;
    if (ctx == null) return;

    final approved = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('تشغيل الإشعارات في الخلفية'),
          content: const Text(
            'لضمان وصول الإشعارات حتى عند إغلاق التطبيق، يرجى السماح '
            'بتجاهل قيود تحسين البطارية لهذا التطبيق.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('لاحقًا'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('فتح الإعدادات'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('سماح الآن'),
            ),
          ],
        );
      },
    );

    if (approved == true) {
      await Permission.ignoreBatteryOptimizations.request();
    } else if (approved == null) {
      await openAppSettings();
    }
    await sp.setBool(_kBatteryOptPrompted, true);
  }

  // -------- تهيئة --------
  Future<void> initialize({int maxRetries = 3}) async {
    if (_initFuture != null) return _initFuture!;
    final retries = maxRetries < 1 ? 1 : maxRetries;
    final future = _doInitialize(maxRetries: retries);
    _initFuture = future;
    try {
      await future;
    } catch (error, stackTrace) {
      _initFuture = null;
      _initialized = false;
      debugPrint(
        '🚫 NotificationService initialize() suppressed failure: $error\n$stackTrace',
      );
    }
  }

  Future<void> _doInitialize({required int maxRetries}) async {
    if (!_supportedPlatform) {
      debugPrint(
          '🔕 Notifications disabled on this platform (non-Android/iOS/macOS).');
      _initialized = false; // ستتجاهل show* النداءات لاحقًا
      return;
    }
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        if (!_tzReady) {
          try {
            tz_data.initializeTimeZones();
            final String timeZoneName = await _getLocalTimeZone();
            tz.setLocalLocation(tz.getLocation(timeZoneName));
            _tzReady = true;
          } catch (e) {
            debugPrint('⚠️ timezone init failed, fallback to UTC: $e');
            tz_data.initializeTimeZones();
            tz.setLocalLocation(tz.getLocation('UTC'));
            _tzReady = true;
          }
        }

        const androidInit =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        final darwinInit = DarwinInitializationSettings(
          requestSoundPermission: true,
          requestBadgePermission: true,
          requestAlertPermission: true,
          onDidReceiveLocalNotification: _onDidReceiveLocalNotification,
        );
        final initSettings = InitializationSettings(
          android: androidInit,
          iOS: darwinInit,
          macOS: darwinInit,
        );

        await _flnp.initialize(
          initSettings,
          onDidReceiveNotificationResponse: _onSelectNotification,
          // 👇 مهم: ممرّر للتاب اللوفلي أعلاه لكي يعمل حتى بالخلفية
          onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
        );

        if (Platform.isAndroid) {
          final androidImpl = _flnp.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

          // طلب صلاحية الإشعارات (Android 13+) — استدعاء ديناميكي لتوافق كل الإصدارات
          try {
            (androidImpl as dynamic)?.requestPermission?.call();
          } catch (_) {}

          // قناة الدردشة (مع صوت raw/notification1.mp3)
          await androidImpl?.createNotificationChannel(
            const AndroidNotificationChannel(
              _messagesChannelId,
              _messagesChannelName,
              description: _messagesChannelDesc,
              importance: Importance.high,
              playSound: true,
              sound: RawResourceAndroidNotificationSound('notification1'),
              enableVibration: true,
            ),
          );

          // قناة التذكيرات
          await androidImpl?.createNotificationChannel(
            const AndroidNotificationChannel(
              _returnsChannelId,
              _returnsChannelName,
              description: _returnsChannelDesc,
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
            ),
          );

          await androidImpl?.createNotificationChannel(
            const AndroidNotificationChannel(
              _patientsChannelId,
              _patientsChannelName,
              description: _patientsChannelDesc,
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
            ),
          );

          await androidImpl?.createNotificationChannel(
            const AndroidNotificationChannel(
              _adminChannelId,
              _adminChannelName,
              description: _adminChannelDesc,
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
            ),
          );
        } else if (Platform.isIOS || Platform.isMacOS) {
          try {
            final ios = _flnp.resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>();
            final mac = _flnp.resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>();
            await ios?.requestPermissions(
                alert: true, badge: true, sound: true);
            await mac?.requestPermissions(
                alert: true, badge: true, sound: true);
          } catch (_) {}
        }

        _initialized = true;
        debugPrint(
          '🔔 NotificationService initialized. Channels ready (attempt $attempt).',
        );
        return;
      } catch (e, stackTrace) {
        _initialized = false;
        final attemptLabel = 'attempt $attempt/$maxRetries';
        debugPrint('❌ NotificationService init error ($attemptLabel): $e');
        if (attempt >= maxRetries) {
          debugPrint(
              '🚫 NotificationService init gave up after $attempt attempts.');
          // الحفاظ على الـ stacktrace الأصلي للمساعدة في التشخيص.
          Error.throwWithStackTrace(e, stackTrace);
        }
        final backoffSeconds = attempt * 2;
        debugPrint(
          '⏳ Retrying notification init in $backoffSeconds seconds...',
        );
        await Future.delayed(Duration(seconds: backoffSeconds));
      }
    }
  }

  static Future<String> _getLocalTimeZone() async {
    try {
      return await FlutterTimezone.getLocalTimezone();
    } catch (_) {
      return 'UTC';
    }
  }

  // iOS < 10 callback (متزامن)
  static void _onDidReceiveLocalNotification(
    int id,
    String? title,
    String? body,
    String? payload,
  ) {
    // يمكن عرض Dialog إن رغبت
  }

  // نقر المستخدم على الإشعار (أمامي/خلفي)
  static Future<void> _onSelectNotification(
    NotificationResponse response,
  ) async {
    final payload = response.payload;
    debugPrint('🔔 onSelectNotification payload=$payload');

    // إن وُجد معالج خارجي، نمرّر له
    if (_externalTapHandler != null) {
      await _externalTapHandler!(payload, response);
      return;
    }

    // تنقّل افتراضي إلى شاشة الدردشة باسم Route مُعدَّل خارجيًا
    if (payload != null &&
        payload.isNotEmpty &&
        _navigatorKey?.currentState != null) {
      try {
        _navigatorKey!.currentState!
            .pushNamed(_chatRouteName, arguments: payload);
      } catch (e) {
        debugPrint('⚠️ navigation on tap failed: $e');
      }
    }
  }

  /// طلب الصلاحيات يدويًا (اختياري)
  Future<void> requestPermissions() async {
    if (!_supportedPlatform) return;
    if (Platform.isAndroid) {
      try {
        final impl = _flnp.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        (impl as dynamic)?.requestPermission?.call();
      } catch (_) {}
    } else if (Platform.isIOS) {
      final ios = _flnp.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      await ios?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (Platform.isMacOS) {
      final mac = _flnp.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>();
      await mac?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  // -------- واجهات الإظهار --------
  void _playFallbackSound() {
    try {
      SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }

  Future<void> showChatNotification({
    required int id,
    required String title,
    required String body,
    String? payload, // conversationId
    String? threadKey, // تجميع أندرويد حسب المحادثة
  }) async {
    if (!_supportedPlatform) {
      _playFallbackSound();
      if (_isWindows) {
        _showInAppFallback(title: title, body: body);
      }
      debugPrint('🔕 showChatNotification skipped (unsupported platform).');
      return;
    }
    if (!_initialized) {
      await initialize();
      if (!_initialized) {
        debugPrint(
            '⚠️ showChatNotification skipped: NotificationService not initialized.');
        return;
      }
    }

    final android = AndroidNotificationDetails(
      _messagesChannelId,
      _messagesChannelName,
      channelDescription: _messagesChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.public,
      playSound: true,
      groupKey: threadKey ?? payload,
      styleInformation: const DefaultStyleInformation(true, true),
    );
    final darwin = const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      // لو أضفت الصوت داخل Bundle على iOS:
      // sound: 'notification1.mp3',
    );
    final details =
        NotificationDetails(android: android, iOS: darwin, macOS: darwin);

    try {
      debugPrint(
          '🔔 showChatNotification(id=$id, title="$title", body="$body", payload="$payload")');
      await _flnp.show(id, title, body, details, payload: payload);
    } catch (e) {
      debugPrint('❌ showChatNotification error: $e');
    }
  }

  /// اسم أوضح لإنشاء إشعار رسالة
  Future<void> showMessageNotification({
    required String fromLabel,
    required String body,
    String? payload,
  }) async {
    final autoId = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
    await showChatNotification(
      id: autoId,
      title: 'لديك رسالة من $fromLabel',
      body: body.isEmpty ? 'رسالة' : body,
      payload: payload,
      threadKey: payload,
    );
  }

  Future<void> showPatientAssignmentNotification({
    required int patientId,
    required String patientName,
  }) async {
    if (!_supportedPlatform) {
      _playFallbackSound();
      if (_isWindows) {
        final trimmedName =
            patientName.trim().isEmpty ? 'مريض جديد' : patientName.trim();
        _showInAppFallback(
          title: 'حالة مرضية جديدة',
          body: 'تم إضافة المريض $trimmedName إلى حسابك الطبي.',
        );
      }
      debugPrint(
          '🔕 showPatientAssignmentNotification skipped (unsupported platform).');
      return;
    }
    if (!_initialized) {
      await initialize();
      if (!_initialized) {
        debugPrint(
            '⚠️ showPatientAssignmentNotification skipped: NotificationService not initialized.');
        return;
      }
    }

    final android = AndroidNotificationDetails(
      _patientsChannelId,
      _patientsChannelName,
      channelDescription: _patientsChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      playSound: true,
    );
    const darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details =
        NotificationDetails(android: android, iOS: darwin, macOS: darwin);

    final safeId = patientId.abs() % 1000000 + 100000;
    final trimmedName =
        patientName.trim().isEmpty ? 'مريض جديد' : patientName.trim();
    const title = 'حالة مرضية جديدة';
    final body = 'تم إضافة المريض $trimmedName إلى حسابك الطبي.';

    try {
      await _flnp.show(
        safeId,
        title,
        body,
        details,
        payload: 'patient:$patientId',
      );
    } catch (e) {
      debugPrint('❌ showPatientAssignmentNotification error: $e');
    }
  }

  Future<void> showAdminNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_supportedPlatform) {
      _playFallbackSound();
      if (_isWindows) {
        _showInAppFallback(title: title, body: body);
      }
      debugPrint('🔕 showAdminNotification skipped (unsupported platform).');
      return;
    }
    if (!_initialized) {
      await initialize();
      if (!_initialized) {
        debugPrint(
            '⚠️ showAdminNotification skipped: NotificationService not initialized.');
        return;
      }
    }

    final android = AndroidNotificationDetails(
      _adminChannelId,
      _adminChannelName,
      channelDescription: _adminChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );
    const darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details =
        NotificationDetails(android: android, iOS: darwin, macOS: darwin);

    try {
      await _flnp.show(id, title, body, details, payload: payload);
    } catch (e) {
      debugPrint('❌ showAdminNotification error: $e');
    }
  }

  Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
  }) async {
    if (!_supportedPlatform) {
      if (_isWindows) {
        _winScheduled[id]?.cancel();
        final delay = scheduledTime.difference(DateTime.now());
        if (delay.isNegative || delay.inMilliseconds == 0) {
          _showInAppFallback(title: title, body: body);
          _playFallbackSound();
          return;
        }
        _winScheduled[id] = Timer(delay, () {
          _showInAppFallback(title: title, body: body);
          _playFallbackSound();
          _winScheduled.remove(id);
        });
        debugPrint('🪟 scheduleNotification (in-app) id=$id at=$scheduledTime');
        return;
      }
      debugPrint('🔕 scheduleNotification skipped (unsupported platform).');
      return;
    }
    if (!_initialized) {
      await initialize();
      if (!_initialized) {
        debugPrint(
            '⚠️ scheduleNotification skipped: NotificationService not initialized.');
        return;
      }
    }

    final tzTime = tz.TZDateTime.from(scheduledTime, tz.local);
    if (tzTime.isBefore(tz.TZDateTime.now(tz.local))) {
      throw ArgumentError('يجب أن يكون الوقت المجدول في المستقبل');
    }

    final android = AndroidNotificationDetails(
      _returnsChannelId,
      _returnsChannelName,
      channelDescription: _returnsChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );
    final darwin = const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details =
        NotificationDetails(android: android, iOS: darwin, macOS: darwin);

    try {
      debugPrint('⏰ scheduleNotification id=$id at=$tzTime');
      await _flnp.zonedSchedule(
        id,
        title,
        body,
        tzTime,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dateAndTime,
        payload: payload ?? id.toString(),
      );
    } catch (e) {
      debugPrint('❌ scheduleNotification error: $e');
    }
  }

  Future<void> cancelNotification(int id) async {
    try {
      if (_isWindows) {
        _winScheduled.remove(id)?.cancel();
      }
      await _flnp.cancel(id);
    } catch (e) {
      debugPrint('❌ cancelNotification error: $e');
    }
  }

  Future<void> cancelAllNotifications() async {
    try {
      if (_isWindows) {
        for (final timer in _winScheduled.values) {
          timer.cancel();
        }
        _winScheduled.clear();
      }
      await _flnp.cancelAll();
    } catch (e) {
      debugPrint('❌ cancelAllNotifications error: $e');
    }
  }
}
