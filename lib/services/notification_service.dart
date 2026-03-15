// lib/services/notification_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aelmamclinic/l10n/raw_string_localizer.dart';
import 'package:aelmamclinic/utils/app_error_reporter.dart';
import 'package:aelmamclinic/utils/app_locale.dart';
import 'package:aelmamclinic/utils/l10n_extensions.dart';
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

  static const String _localePrefsKey = 'app.locale_code';
  static const String _messagesChannelBaseId = 'messages_channel';
  static const String _returnsChannelBaseId = 'returns_channel';
  static const String _patientsChannelBaseId = 'patients_channel';
  static const String _adminChannelBaseId = 'admin_channel';
  static const String _remoteFallbackChannelId = 'elmam_high_priority';
  static const String _remoteFallbackChannelName = 'Elmam High Priority Alerts';
  static const String _remoteFallbackChannelDescription =
      'Fallback channel for remote FCM messages when the app is closed or the device is asleep.';
  static const String _kBatteryOptPrompted = 'notif.battery_opt_prompted';
  static const String _kBatteryOptPromptedAt = 'notif.battery_opt_prompted_at';
  static const String _kScheduledEntriesKey = 'notif.scheduled_entries_v1';
  static const Duration _kBatteryOptRepromptAfter = Duration(days: 3);

  bool _initialized = false;
  bool get isReady => _initialized;

  bool _tzReady = false;
  Future<void>? _initFuture;
  final Map<int, Timer> _winScheduled = <int, Timer>{};
  String _languageCode = AppLocale.defaultLanguageCode;

  bool get _supportedPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);
  bool get _isWindows => !kIsWeb && Platform.isWindows;
  static String get androidRemoteFallbackChannelId => _remoteFallbackChannelId;
  String get currentLanguageCode => AppLocale.normalize(_languageCode);
  bool get _isArabic => AppLocale.isRtlCode(currentLanguageCode);
  String get _messagesChannelId =>
      '${_messagesChannelBaseId}_${currentLanguageCode}_v2';
  String get _returnsChannelId =>
      '${_returnsChannelBaseId}_${currentLanguageCode}_v2';
  String get _patientsChannelId =>
      '${_patientsChannelBaseId}_${currentLanguageCode}_v2';
  String get _adminChannelId =>
      '${_adminChannelBaseId}_${currentLanguageCode}_v2';
  String get _messagesChannelName =>
      _isArabic ? 'رسائل الدردشة' : 'Chat messages';
  String get _messagesChannelDesc => _isArabic
      ? 'إشعارات رسائل الدردشة مع صوت مخصص'
      : 'Notifications for chat messages with a custom sound';
  String get _returnsChannelName =>
      _isArabic ? 'تذكير العودات' : 'Follow-up reminders';
  String get _returnsChannelDesc => _isArabic
      ? 'إشعارات تذكير بمواعيد العودات'
      : 'Notifications for scheduled follow-up reminders';
  String get _patientsChannelName =>
      _isArabic ? 'تنبيهات المرضى' : 'Patient alerts';
  String get _patientsChannelDesc => _isArabic
      ? 'إشعارات الحالات المرضية الجديدة للأطباء'
      : 'Notifications for new patient cases assigned to doctors';
  String get _adminChannelName =>
      _isArabic ? 'تنبيهات الإدارة' : 'Admin alerts';
  String get _adminChannelDesc => _isArabic
      ? 'إشعارات طلبات الترقية ورسائل خدمة العملاء'
      : 'Notifications for upgrade requests and customer support';

  String translateRaw(String raw, {String? languageCode}) {
    return RawStringLocalizer.translate(
      raw,
      languageCode: AppLocale.normalize(languageCode ?? currentLanguageCode),
    );
  }

  String _tr(String raw) => translateRaw(raw);

  Future<void> updateLanguageCode(String languageCode) async {
    _languageCode = AppLocale.normalize(languageCode);
    if (_initialized || _isWindows) {
      if (_initialized && Platform.isAndroid) {
        await _createAndroidChannels();
      }
      await _refreshScheduledNotificationsForLanguage();
    }
  }

  Future<void> _loadPreferredLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _languageCode = AppLocale.normalize(
        prefs.getString(_localePrefsKey),
      );
    } catch (_) {
      _languageCode = AppLocale.defaultLanguageCode;
    }
  }

  Future<void> _createAndroidChannels() async {
    if (!Platform.isAndroid) return;
    final androidImpl = _flnp.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    try {
      (androidImpl as dynamic)?.requestPermission?.call();
    } catch (_) {}

    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _remoteFallbackChannelId,
        _remoteFallbackChannelName,
        description: _remoteFallbackChannelDescription,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );

    await androidImpl?.createNotificationChannel(
      AndroidNotificationChannel(
        _messagesChannelId,
        _messagesChannelName,
        description: _messagesChannelDesc,
        importance: Importance.high,
        playSound: true,
        sound: const RawResourceAndroidNotificationSound('notification1'),
        enableVibration: true,
      ),
    );

    await androidImpl?.createNotificationChannel(
      AndroidNotificationChannel(
        _returnsChannelId,
        _returnsChannelName,
        description: _returnsChannelDesc,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );

    await androidImpl?.createNotificationChannel(
      AndroidNotificationChannel(
        _patientsChannelId,
        _patientsChannelName,
        description: _patientsChannelDesc,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );

    await androidImpl?.createNotificationChannel(
      AndroidNotificationChannel(
        _adminChannelId,
        _adminChannelName,
        description: _adminChannelDesc,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  Future<Map<String, dynamic>> _loadScheduledEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kScheduledEntriesKey);
      if (raw == null || raw.trim().isEmpty) {
        return <String, dynamic>{};
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _saveScheduledEntries(Map<String, dynamic> entries) async {
    final prefs = await SharedPreferences.getInstance();
    if (entries.isEmpty) {
      await prefs.remove(_kScheduledEntriesKey);
      return;
    }
    await prefs.setString(_kScheduledEntriesKey, jsonEncode(entries));
  }

  Future<void> _persistScheduledNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
  }) async {
    final entries = await _loadScheduledEntries();
    entries['$id'] = <String, dynamic>{
      'title': title,
      'body': body,
      'scheduledTime': scheduledTime.toIso8601String(),
      'payload': payload,
    };
    await _saveScheduledEntries(entries);
  }

  Future<void> _removeScheduledNotificationRecord(int id) async {
    final entries = await _loadScheduledEntries();
    if (entries.remove('$id') != null) {
      await _saveScheduledEntries(entries);
    }
  }

  Future<void> _clearScheduledNotificationRecords() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kScheduledEntriesKey);
  }

  Future<void> _refreshScheduledNotificationsForLanguage() async {
    final entries = await _loadScheduledEntries();
    if (entries.isEmpty) return;

    final now = DateTime.now();
    final expiredIds = <String>[];
    for (final entry in entries.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final id = int.tryParse(entry.key);
      final title = value['title']?.toString() ?? '';
      final body = value['body']?.toString() ?? '';
      final payload = value['payload']?.toString();
      final scheduledTime = DateTime.tryParse(
        value['scheduledTime']?.toString() ?? '',
      );

      if (id == null ||
          scheduledTime == null ||
          scheduledTime.isBefore(now)) {
        expiredIds.add(entry.key);
        continue;
      }

      await _scheduleLocalizedNotification(
        id: id,
        title: title,
        body: body,
        scheduledTime: scheduledTime,
        payload: payload,
        persist: false,
      );
    }

    if (expiredIds.isNotEmpty) {
      for (final id in expiredIds) {
        entries.remove(id);
      }
      await _saveScheduledEntries(entries);
    }
  }

  Future<void> _scheduleLocalizedNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
    required bool persist,
  }) async {
    final localizedTitle = _tr(title);
    final localizedBody = _tr(body);
    if (!_supportedPlatform) {
      if (_isWindows) {
        _winScheduled[id]?.cancel();
        final delay = scheduledTime.difference(DateTime.now());
        if (delay.isNegative || delay.inMilliseconds == 0) {
          _showInAppFallback(title: localizedTitle, body: localizedBody);
          _playFallbackSound();
          if (persist) {
            await _removeScheduledNotificationRecord(id);
          }
          return;
        }
        _winScheduled[id] = Timer(delay, () {
          _showInAppFallback(title: localizedTitle, body: localizedBody);
          _playFallbackSound();
          _winScheduled.remove(id);
          unawaited(_removeScheduledNotificationRecord(id));
        });
        if (persist) {
          await _persistScheduledNotification(
            id: id,
            title: title,
            body: body,
            scheduledTime: scheduledTime,
            payload: payload,
          );
        }
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
      throw ArgumentError(_tr('يجب أن يكون الوقت المجدول في المستقبل'));
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

    debugPrint('⏰ scheduleNotification id=$id at=$tzTime');
    await _flnp.zonedSchedule(
      id,
      localizedTitle,
      localizedBody,
      tzTime,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.dateAndTime,
      payload: payload ?? id.toString(),
    );

    if (persist) {
      await _persistScheduledNotification(
        id: id,
        title: title,
        body: body,
        scheduledTime: scheduledTime,
        payload: payload,
      );
    }
  }

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
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) {
      await sp.setBool(_kBatteryOptPrompted, true);
      await sp.remove(_kBatteryOptPromptedAt);
      return;
    }

    final prompted = sp.getBool(_kBatteryOptPrompted) ?? false;
    final lastPromptRaw = sp.getString(_kBatteryOptPromptedAt);
    final lastPromptAt =
        lastPromptRaw == null ? null : DateTime.tryParse(lastPromptRaw);
    if (prompted &&
        lastPromptAt != null &&
        DateTime.now().difference(lastPromptAt) < _kBatteryOptRepromptAfter) {
      return;
    }

    final ctx = _navigatorKey?.currentContext;
    if (ctx == null) return;

    final approved = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: Text(context.tr('notif_background_title')),
          content: Text(context.tr('notif_background_body')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('common_later')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: Text(context.tr('common_open_settings')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.tr('common_allow_now')),
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
    final refreshed = await Permission.ignoreBatteryOptimizations.status;
    final granted = refreshed.isGranted;
    await sp.setBool(_kBatteryOptPrompted, granted);
    if (granted) {
      await sp.remove(_kBatteryOptPromptedAt);
    } else {
      await sp.setString(_kBatteryOptPromptedAt, DateTime.now().toIso8601String());
    }
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
    await _loadPreferredLanguage();
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
          await _createAndroidChannels();
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
        await _refreshScheduledNotificationsForLanguage();
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
    await _dispatchPayloadTap(response.payload, response: response);
  }

  static Future<void> dispatchPayloadTap(String? payload) async {
    await _dispatchPayloadTap(payload);
  }

  static Future<void> _dispatchPayloadTap(
    String? payload, {
    NotificationResponse? response,
  }) async {
    debugPrint('🔔 onSelectNotification payload=$payload');
    final effectiveResponse =
        response ??
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: payload,
        );

    // إن وُجد معالج خارجي، نمرّر له
    if (_externalTapHandler != null) {
      await _externalTapHandler!(payload, effectiveResponse);
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
    final localizedTitle = _tr(title);
    final localizedBody = _tr(body);
    if (!_supportedPlatform) {
      _playFallbackSound();
      if (_isWindows) {
        _showInAppFallback(title: localizedTitle, body: localizedBody);
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
          '🔔 showChatNotification(id=$id, title="$localizedTitle", body="$localizedBody", payload="$payload")');
      await _flnp.show(
        id,
        localizedTitle,
        localizedBody,
        details,
        payload: payload,
      );
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
      title: _tr('لديك رسالة من $fromLabel'),
      body: body.isEmpty ? _tr('رسالة') : body,
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
            patientName.trim().isEmpty ? _tr('مريض جديد') : patientName.trim();
        _showInAppFallback(
          title: _tr('حالة مرضية جديدة'),
          body: _tr('تم إضافة المريض $trimmedName إلى حسابك الطبي.'),
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
        patientName.trim().isEmpty ? _tr('مريض جديد') : patientName.trim();
    final title = _tr('حالة مرضية جديدة');
    final body = _tr('تم إضافة المريض $trimmedName إلى حسابك الطبي.');

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
    final localizedTitle = _tr(title);
    final localizedBody = _tr(body);
    if (!_supportedPlatform) {
      _playFallbackSound();
      if (_isWindows) {
        _showInAppFallback(title: localizedTitle, body: localizedBody);
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
      await _flnp.show(
        id,
        localizedTitle,
        localizedBody,
        details,
        payload: payload,
      );
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
    try {
      await _scheduleLocalizedNotification(
        id: id,
        title: title,
        body: body,
        scheduledTime: scheduledTime,
        payload: payload,
        persist: true,
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
      await _removeScheduledNotificationRecord(id);
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
      await _clearScheduledNotificationRecords();
    } catch (e) {
      debugPrint('❌ cancelAllNotifications error: $e');
    }
  }
}
