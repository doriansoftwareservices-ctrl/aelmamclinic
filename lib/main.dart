// lib/main.dart
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:aelmamclinic/utils/toast_utils.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// SQLite (Windows/Linux/macOS via FFI)
import 'package:sqlite3/open.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sq;

// مسارات آمنة للتخزين
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:path/path.dart' as p;
import 'package:aelmamclinic/utils/app_paths.dart';

/*──────── مزوّدات الحالة ────────*/
import 'providers/activation_provider.dart';
import 'providers/appointment_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/repository_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';

/*──────── خدمات وودجتس عامة ────────*/
import 'services/notification_service.dart';
import 'services/chat_realtime_notifier.dart';
import 'services/db_service.dart';
import 'services/push_notifications_service.dart';
import 'services/network_status_service.dart';
import 'widgets/activation_listener.dart';
import 'widgets/auth_guard_listener.dart';
import 'widgets/responsive_frame.dart';

/*──────── شاشات ────────*/
import 'screens/activation_screen.dart';
import 'screens/statistics/statistics_overview_screen.dart';
import 'screens/admin/admin_dashboard_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/repository/menu/repository_menu_screen.dart';
import 'screens/repository/items/add_item_screen.dart';
import 'screens/repository/items/view_items_screen.dart';
import 'screens/repository/purchases_consumptions/pc_menu_screen.dart';
import 'screens/repository/purchases_consumptions/new_purchase_screen.dart';
import 'screens/repository/purchases_consumptions/view_pc_screen.dart';
import 'screens/repository/statistics/repository_statistics_screen.dart';
import 'screens/repository/alerts/alert_menu_screen.dart';
import 'screens/repository/alerts/create_alert_screen.dart';
import 'screens/repository/alerts/view_alerts_screen.dart';
import 'screens/repository/health/repository_health_screen.dart';

// للدردشة
import 'screens/chat/chat_room_screen.dart';
import 'models/chat_models.dart';
import 'screens/patients/view_patient_screen.dart';

/*──────── الثيم/الثوابت ────────*/
import 'core/theme.dart';
import 'core/constants.dart';
import 'core/nhost_manager.dart';
import 'core/nhost_config.dart';
import 'utils/notifications_helper.dart';
import 'core/backend_lock.dart';
import 'screens/offline/offline_mode_screen.dart';
import 'services/nhost_graphql_service.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'utils/app_error_reporter.dart';
import 'firebase_options.dart';

/// هل المنصّة تدعم flutter_local_notifications؟ (Android/iOS/macOS)
bool get _pushSupported {
  try {
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows;
  } catch (_) {
    return false;
  }
}

/// مفاتيح ملاحة عامة لفتح الشاشات من الإشعارات
final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
bool _f11Down = false;

Future<void> _toggleFullscreen() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
  final isFull = await windowManager.isFullScreen();
  await windowManager.setFullScreen(!isFull);
}

bool _isNetworkErrorMessage(String message) {
  final s = message.toLowerCase();
  return s.contains('network') ||
      s.contains('socket') ||
      s.contains('timeout') ||
      s.contains('timed out') ||
      s.contains('failed host lookup') ||
      s.contains('bad gateway') ||
      s.contains('semaphore timeout') ||
      s.contains('semaphore') ||
      s.contains('service temporarily unavailable') ||
      s.contains('responseformatexception') ||
      s.contains('formatexception') ||
      s.contains('unexpected character') ||
      s.contains('document is empty') ||
      s.contains('eof') ||
      s.contains('503') ||
      s.contains('502');
}

DynamicLibrary _loadWindowsSqliteLibrary() {
  final exeDir = File(Platform.resolvedExecutable).parent;
  final candidates = <String>[
    p.join(exeDir.path, 'sqlite3.dll'),
    r'C:\sqlite\sqlite3.dll',
  ];

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      dev.log('Loading sqlite3 from $candidate', name: 'sqlite');
      return DynamicLibrary.open(candidate);
    }
  }

  dev.log(
    'sqlite3.dll not found in explicit locations, falling back to default lookup',
    name: 'sqlite',
  );
  return DynamicLibrary.open('sqlite3.dll');
}

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    if (Platform.isWindows) {
      // توحيد مجلد العمل إلى مسار قابل للكتابة (تجنب Program Files)
      try {
        final dataRoot = await AppPaths.dataRoot();
        Directory.current = dataRoot;
      } catch (_) {}
    }

    if (BackendLock.isOffline) {
      BackendLock.enforceOfflineNetwork();
      dev.log(
        'Backend access disabled – running in offline placeholder mode',
        name: 'BOOT',
      );
      runApp(const OfflineModeApp());
      return;
    }

    // تحميل إعدادات Nhost من ملفات الإعدادات المحلية إن وُجدت.
    await AppConstants.loadRuntimeOverrides();
    // تفعيل عميل Nhost بشكل مبكر لضمان جاهزية GraphQL/Auth/Storage.
    NhostManager.client;
    // مراقبة الشبكة (Online/Offline)
    unawaited(NetworkStatusService.instance.start());

    // تهيئة Firebase + معالج الخلفية (Android/iOS فقط)
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      FirebaseMessaging.onBackgroundMessage(
        PushNotificationsService.firebaseMessagingBackgroundHandler,
      );
    }
    AppConstants.debugLog(
      'Nhost config: subdomain=${NhostConfig.subdomain}, '
      'region=${NhostConfig.region}, '
      'graphql=${NhostConfig.graphqlUrl}, '
      'auth=${NhostConfig.authUrl}, '
      'storage=${NhostConfig.storageUrl}, '
      'functions=${NhostConfig.functionsUrl}',
      tag: 'CONFIG',
    );
    AppConstants.debugLog(
      'Initialized Nhost backend',
      tag: 'BOOT',
    );

    // إنشاء مجلد ثابت على ويندوز ليتوافق مع DBService
    if (Platform.isWindows) {
      try {
        final root = await AppPaths.dataRoot();
        await root.create(recursive: true);
      } catch (_) {}
    }

    // SQLite عبر FFI على الديسكتوب
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (Platform.isWindows) {
        open.overrideForAll(_loadWindowsSqliteLibrary);
      }
      sqfliteFfiInit();
      sq.databaseFactory = databaseFactoryFfi;
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.ensureInitialized();
      HardwareKeyboard.instance.addHandler((event) {
        if (event.logicalKey == LogicalKeyboardKey.f11) {
          if (event is KeyDownEvent && !_f11Down) {
            _f11Down = true;
            _toggleFullscreen();
          } else if (event is KeyUpEvent) {
            _f11Down = false;
          }
          return true;
        }
        return false;
      });
    }

    // التقاط أخطاء Flutter
    FlutterError.onError = (details) async {
      final message = details.exceptionAsString();
      if (message.contains('hardware_keyboard.dart') ||
          message.contains('raw_keyboard.dart') ||
          message.contains('keysPressed')) {
        FlutterError.presentError(details);
        return;
      }
      // تجاهل أخطاء الـ overflow الشائعة وأخطاء deactivated ancestor لتفادي كسر الـ inspector
      if (message.contains('A RenderFlex overflowed') ||
          message.contains('Looking up a deactivated widget')) {
        FlutterError.dumpErrorToConsole(details);
        return;
      }
      debugPrint("FlutterError: ${details.exception}");
      final raw = details.exceptionAsString();
      final isNet = _isNetworkErrorMessage(raw);
      final msg = isNet
          ? 'يبدو ان الشبكة غير مستقرة لديك'
          : 'حدث خطأ غير متوقع. تم تسجيله.';
      if (isNet) {
        AppErrorReporter.info(msg, error: details.exception, stack: details.stack);
      } else {
        AppErrorReporter.report(msg, error: details.exception, stack: details.stack);
      }
      await _logCrash(details.exceptionAsString(), details.stack.toString());
      try {
        FlutterError.presentError(details);
      } catch (_) {
        FlutterError.dumpErrorToConsole(details);
      }
    };

    // إشعارات محلية فقط
    if (_pushSupported) {
      await _requestNotificationPermission();

      await NotificationService().initialize();
      NotificationService.attachNavigator(
        _navKey,
        chatRouteName: ChatRoomLoader.routeName,
      );
      NotificationService.setOnNotificationTap((payload, response) async {
        if (payload != null && payload.startsWith('patient:')) {
          final parts = payload.split(':');
          final id = parts.length > 1 ? int.tryParse(parts[1]) : null;
          if (id != null) {
            try {
              final patient = await DBService.instance.getPatientById(id);
              final navigator = _navKey.currentState;
              if (patient != null && navigator != null) {
                navigator.push(
                  MaterialPageRoute(
                    builder: (_) => ViewPatientScreen(patient: patient),
                  ),
                );
              }
            } catch (e) {
              debugPrint('⚠️ فشل فتح المريض من الإشعار: $e');
            }
          }
          return;
        }

        if (payload != null &&
            payload.isNotEmpty &&
            _navKey.currentState != null) {
          try {
            _navKey.currentState!
                .pushNamed(ChatRoomLoader.routeName, arguments: payload);
          } catch (e) {
            debugPrint('⚠️ navigation on tap failed: $e');
          }
        }
      });

      // اختبار إشعار في وضع التطوير
      if (kDebugMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            if (NotificationService().isReady) {
              await NotificationService().showChatNotification(
                id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
                title: 'اختبار إشعار الدردشة',
                body: 'لو وصلك هذا التنبيه فالقناة تعمل والصوت مضبوط',
                payload: 'TEST_CONV_ID',
              );
            }
          } catch (_) {}
        });
      }

      await NotificationsHelper.instance.init();
    } else {
      debugPrint('🔕 Notifications disabled on this platform.');
    }

    // التحقق من تلاعب الوقت عند الإقلاع
    await _checkTimeTampering();

    // تحميل حالة التفعيل
    final prefs = await SharedPreferences.getInstance();
    final bool isActivated = prefs.getBool('isActivated') ?? false;
    final String? expiryString = prefs.getString('expiryDate');
    final DateTime? expiryDate =
        expiryString != null ? DateTime.parse(expiryString) : null;
    final String? lastCheckString = prefs.getString('lastTimeCheck');
    final DateTime? lastTimeCheck =
        lastCheckString != null ? DateTime.parse(lastCheckString) : null;

    // خدمات
    final db = DBService.instance;
    await db.database;

    final authProvider = AuthProvider();
    await authProvider.init();

    runApp(
      MultiProvider(
        providers: [
          Provider<DBService>.value(value: db),
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider(
            create: (_) => ActivationProvider.withInitial(
              isActivated: isActivated,
              expiryDate: expiryDate,
              lastTimeCheck: lastTimeCheck,
            ),
          ),
          ChangeNotifierProvider(
            create: (_) => AppointmentProvider()..loadAppointments(),
          ),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProxyProvider<AuthProvider, RepositoryProvider>(
            create: (_) => RepositoryProvider(),
            update: (_, auth, repo) {
              final rp = repo ?? RepositoryProvider();
              if (auth.isLoggedIn) {
                Future.microtask(() => rp.onAuthChanged(auth.accountId));
              } else {
                Future.microtask(() => rp.onAuthChanged(null));
              }
              return rp;
            },
          ),
          // ChatProvider يعتمد على AuthProvider
          ChangeNotifierProxyProvider<AuthProvider, ChatProvider>(
            create: (_) => ChatProvider(),
            update: (_, auth, previous) {
              final cp = previous ?? ChatProvider();

              if (auth.isLoggedIn) {
                Future.microtask(() async {
                  await PushNotificationsService.instance.initForAuth(
                    accountId: auth.accountId,
                    role: auth.role,
                  );
                });
                Future.microtask(() async {
                  final uid = NhostManager.client.auth.currentUser?.id;
                  if (uid == null || uid.isEmpty) return;

                  String? accId = auth.accountId;
                  accId ??= await cp.fetchAccountIdForCurrentUser(
                    isSuperAdmin: auth.isSuperAdmin,
                  );

                  await ChatRealtimeNotifier.instance.start(
                    accountId: accId, // قد تكون null (كل الحسابات)
                    myUid: uid,
                  );
                });
              } else {
                ChatRealtimeNotifier.instance.stop();
                PushNotificationsService.instance.dispose();
                cp.onSignedOut();
              }

              if (auth.isLoggedIn && !cp.ready) {
                Future.microtask(() async {
                  String? accId = auth.accountId;
                  accId ??= await cp.fetchAccountIdForCurrentUser(
                    isSuperAdmin: auth.isSuperAdmin,
                  );
                  if ((accId == null || accId.isEmpty) && !auth.isSuperAdmin) {
                    return;
                  }
                  await cp.bootstrap(
                    accountId:
                        (accId != null && accId.isNotEmpty) ? accId : null,
                    role: auth.role ?? '',
                    isSuperAdmin: auth.isSuperAdmin,
                  );
                });
              }

              return cp;
            },
          ),
        ],
        child: const MyApp(),
      ),
    );
  }, (error, stack) async {
    debugPrint("Zoned error: $error\n$stack");
    final raw = error.toString();
    final isNet = _isNetworkErrorMessage(raw);
    final msg = isNet
        ? 'يبدو ان الشبكة غير مستقرة لديك'
        : 'حدث خطأ غير متوقع. تم تسجيله.';
    if (isNet) {
      AppErrorReporter.info(msg, error: error, stack: stack);
    } else {
      AppErrorReporter.report(msg, error: error, stack: stack);
    }
    await _logCrash(error.toString(), stack.toString());
  });
}

// التحقق من تلاعب الوقت
Future<void> _checkTimeTampering() async {
  final prefs = await SharedPreferences.getInstance();
  final lastCheck = prefs.getString('lastTimeCheck');

  if (lastCheck != null) {
    final lastCheckTime = DateTime.parse(lastCheck);
    if (DateTime.now().isBefore(lastCheckTime)) {
      await prefs.setBool('isActivated', false);
      await prefs.remove('expiryDate');
    }
  }
  await prefs.setString('lastTimeCheck', DateTime.now().toIso8601String());
}

// تسجيل الأخطاء في ملف
Future<void> _logCrash(String error, String stack) async {
  try {
    dev.log(
      'App crash captured',
      error: error,
      stackTrace: StackTrace.fromString(stack),
    );
    final String filePath = await _crashLogFilePath();
    final file = File(filePath);
    await file.create(recursive: true);
    final timestamp = DateTime.now().toIso8601String();
    await file.writeAsString(
      '\n[$timestamp]\nERROR: $error\nSTACKTRACE:\n$stack\n',
      mode: FileMode.append,
    );
  } catch (e) {
    // ignore: avoid_print
    print('Failed to write crash log: $e');
  }
}

// اختيار مسار صالح حسب المنصّة
Future<String> _crashLogFilePath() async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final dir = await AppPaths.logsDir();
    return p.join(dir.path, 'crash_log.txt');
  }
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await path_provider.getApplicationSupportDirectory();
    final logs = Directory(p.join(dir.path, 'logs'));
    await logs.create(recursive: true);
    return p.join(logs.path, 'crash_log.txt');
  }
  final dir = await path_provider.getApplicationDocumentsDirectory();
  final logs = Directory(p.join(dir.path, 'logs'));
  await logs.create(recursive: true);
  return p.join(logs.path, 'crash_log.txt');
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: AppConstants.appName,
      navigatorKey: _navKey,
      scaffoldMessengerKey: AppErrorReporter.messengerKey,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeProvider.themeMode,
      builder: (ctx, child) {
        return ActivationListener(
          child: AuthGuardListener(
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: ResponsiveFrame(child: child!),
            ),
          ),
        );
      },
      initialRoute: '/',
      onGenerateRoute: (settings) {
        late Widget page;
        switch (settings.name) {
          case '/':
            page = const AppInitializer();
            break;
          case '/activation':
            page = const ActivationScreen();
            break;
          case RepositoryMenuScreen.routeName:
            page = const RepositoryMenuScreen();
            break;
          case AddItemScreen.routeName:
            page = const AddItemScreen();
            break;
          case ViewItemsScreen.routeName:
            page = const ViewItemsScreen();
            break;
          case PcMenuScreen.routeName:
            page = const PcMenuScreen();
            break;
          case NewPurchaseScreen.routeName:
            page = const NewPurchaseScreen();
            break;
          case ViewPCScreen.routeName:
            page = const ViewPCScreen();
            break;
          case RepositoryStatisticsScreen.routeName:
            page = const RepositoryStatisticsScreen();
            break;
          case AlertMenuScreen.routeName:
            page = const AlertMenuScreen();
            break;
          case CreateAlertScreen.routeName:
            page = const CreateAlertScreen();
            break;
          case ViewAlertsScreen.routeName:
            page = const ViewAlertsScreen();
            break;
          case RepositoryHealthScreen.routeName:
            page = const RepositoryHealthScreen();
            break;
          case '/admin':
            page = const AdminDashboardScreen();
            break;
          // فتح غرفة الدردشة عبر ConversationId
          case ChatRoomLoader.routeName:
            final arg = settings.arguments;
            final convId = (arg is String) ? arg : (arg?.toString() ?? '');
            page = ChatRoomLoader(conversationId: convId);
            break;
          default:
            return null;
        }
        return MaterialPageRoute(
          builder: (_) => page,
          settings: settings,
          maintainState: false,
        );
      },
    );
  }
}

class AppInitializer extends StatefulWidget {
  const AppInitializer({super.key});

  @override
  State<AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<AppInitializer> {
  bool _wasActivated = false;
  bool _didNavigateToLogin = false;

  @override
  void initState() {
    super.initState();
    final initialActivated = context.read<ActivationProvider>().isActivated;
    _wasActivated = initialActivated;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService().promptBatteryOptimizationIfNeeded();
    });
  }

  void _maybeNavigateOnActivation({
    required bool activated,
    required bool loggedIn,
  }) {
    if (!_didNavigateToLogin && !_wasActivated && activated && !loggedIn) {
      _didNavigateToLogin = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      });
    }
    _wasActivated = activated;
  }

  @override
  Widget build(BuildContext context) {
    final activation = context.watch<ActivationProvider>();
    final auth = context.watch<AuthProvider>();

    final activationEnabled = AppConstants.activationGateEnabled;
    final isActivated = activationEnabled ? activation.isActivated : true;

    if (activationEnabled) {
      _maybeNavigateOnActivation(
        activated: activation.isActivated,
        loggedIn: auth.isLoggedIn,
      );
    }

    if (!isActivated) {
      return const ActivationScreen();
    }
    if (!auth.isLoggedIn) {
      return const LoginScreen();
    }
    if (!auth.hasNhostSession && NetworkStatusService.instance.isOnline) {
      return const _SessionRestoreScreen();
    }
    if (auth.isSuperAdmin) {
      return const AdminDashboardScreen();
    }
    if ((auth.accountId ?? '').trim().isEmpty) {
      return const _PostLoginBootstrapScreen();
    }
    return const StatisticsOverviewScreen();
  }
}

class _PostLoginBootstrapScreen extends StatefulWidget {
  const _PostLoginBootstrapScreen();

  @override
  State<_PostLoginBootstrapScreen> createState() =>
      _PostLoginBootstrapScreenState();
}

class _PostLoginBootstrapScreenState extends State<_PostLoginBootstrapScreen> {
  bool _working = false;
  String? _message;
  StreamSubscription<bool>? _netSub;
  Timer? _retryTimer;
  bool _autoReloginAttempted = false;
  bool _autoReloginInFlight = false;

  static const _rememberMeKey = 'auth.remember_me';
  static const _rememberEmailKey = 'auth.remember_email';
  static const _rememberPassKey = 'auth.remember_pass';

  @override
  void initState() {
    super.initState();
    _netSub = NetworkStatusService.instance.changes.listen((online) {
      if (!online || !mounted) return;
      final auth = context.read<AuthProvider>();
      if (_working) return;
      if (auth.isSuperAdmin) return;
      if ((auth.accountId ?? '').trim().isNotEmpty) return;
      _probe();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _probe());
  }

  Future<void> _probe() async {
    if (_working) return;
    _retryTimer?.cancel();
    _working = true;
    final auth = context.read<AuthProvider>();
    if (!NetworkStatusService.instance.isOnline) {
      if (mounted) {
        setState(() => _message =
            'لا يوجد إنترنت لتجهيز الحساب الآن. سيتم الانتظار حتى يعود الاتصال…');
      }
      _working = false;
      return;
    }
    for (int i = 0; i < 8; i++) {
      if (!NetworkStatusService.instance.isOnline) {
        if (mounted) {
          setState(() => _message =
              'OFFLINE: تجهيز الحساب يحتاج إنترنت. سيتم المتابعة تلقائيًا عند رجوع الاتصال…');
        }
        _working = false;
        return;
      }
      final result = await auth.refreshAndValidateCurrentUser();
      if (!mounted) return;
      if (auth.isSuperAdmin) {
        _working = false;
        return;
      }
      if (result.status == AuthSessionStatus.networkError ||
          result.status == AuthSessionStatus.unknown) {
        if (mounted) {
          setState(() => _message = 'يبدو ان الشبكة غير مستقرة لديك');
        }
        _working = false;
        _retryTimer = Timer(const Duration(seconds: 5), () {
          if (!mounted) return;
          _probe();
        });
        return;
      }
      if ((auth.accountId ?? '').trim().isNotEmpty) {
        _working = false;
        return;
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    if (!mounted) return;
    setState(() => _message =
        'تعذّر تجهيز الحساب حاليًا. سيتم إعادة المحاولة تلقائيًا.');
    unawaited(_tryAutoRelogin(auth));
    _retryTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      _probe();
    });
    _working = false;
  }

  Future<void> _tryAutoRelogin(AuthProvider auth) async {
    if (_autoReloginInFlight || _autoReloginAttempted) return;
    _autoReloginInFlight = true;
    _autoReloginAttempted = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final remember = sp.getBool(_rememberMeKey) ?? false;
      if (!remember) return;
      final email = sp.getString(_rememberEmailKey) ?? '';
      final pass = sp.getString(_rememberPassKey) ?? '';
      if (email.isEmpty || pass.isEmpty) return;
      if (!NetworkStatusService.instance.isOnline) return;

      await auth.signOut();
      await auth.signIn(email, pass);
      await auth.refreshAndValidateCurrentUser();
    } catch (_) {
      // سيتم عرض رسالة الشبكة العامة من طبقة الخطأ
    } finally {
      _autoReloginInFlight = false;
    }
  }

  @override
  void dispose() {
    _netSub?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_message ?? 'جارٍ تجهيز الحساب...'),
          ],
        ),
      ),
    );
  }
}

class _SessionRestoreScreen extends StatefulWidget {
  const _SessionRestoreScreen();

  @override
  State<_SessionRestoreScreen> createState() => _SessionRestoreScreenState();
}

class _SessionRestoreScreenState extends State<_SessionRestoreScreen> {
  bool _working = false;
  String? _message;
  StreamSubscription<bool>? _netSub;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _netSub = NetworkStatusService.instance.changes.listen((online) {
      if (!online || !mounted) return;
      if (_working) return;
      _restore();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  Future<void> _restore() async {
    if (_working) return;
    _retryTimer?.cancel();
    _working = true;
    final auth = context.read<AuthProvider>();
    if (!NetworkStatusService.instance.isOnline) {
      if (mounted) {
        setState(() => _message =
            'لا يوجد إنترنت لاستعادة الجلسة. سيتم الانتظار حتى يعود الاتصال…');
      }
      _working = false;
      return;
    }
    setState(() => _message = 'جارٍ استعادة الجلسة...');
    final ok = await auth.ensureNhostSessionReady(reason: 'appStart');
    if (ok) {
      await auth.refreshAndValidateCurrentUser();
    }
    _working = false;
    if (!mounted) return;
    if (!auth.hasNhostSession) {
      setState(() => _message =
          'تعذّر استعادة الجلسة. سيتم إعادة المحاولة تلقائيًا.');
      _retryTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        _restore();
      });
    }
  }

  @override
  void dispose() {
    _netSub?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_message ?? 'جارٍ استعادة الجلسة...'),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _restore,
              child: const Text('إعادة المحاولة الآن'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _requestNotificationPermission() async {
  if (!_pushSupported) return;
  try {
    final status = await Permission.notification.status;
    if (status.isDenied || status.isRestricted) {
      final result = await Permission.notification.request();
      if (result.isDenied) {
        await ToastUtils.show(
          'هذا التطبيق يحتاج إلى إذن الإشعارات لتذكيرك بالمواعيد.',
        );
      } else if (result.isPermanentlyDenied) {
        await ToastUtils.show('يرجى تمكين الإشعارات من إعدادات التطبيق.');
        openAppSettings();
      }
    }
  } catch (_) {}
}

/*──────────────────────────── ChatRoomLoader ────────────────────────────*/
/// ويدجت وسيطة لفتح غرفة الدردشة عبر ConversationId فقط.
/// تُستخدم من إشعار: payload = conversationId
class ChatRoomLoader extends StatefulWidget {
  static const String routeName = '/chat/room';

  final String conversationId;
  const ChatRoomLoader({super.key, required this.conversationId});

  @override
  State<ChatRoomLoader> createState() => _ChatRoomLoaderState();
}

class _ChatRoomLoaderState extends State<ChatRoomLoader> {
  bool _loading = true;
  String? _error;
  ChatConversation? _conv;
  final GraphQLClient _gql = NhostGraphqlService.buildClient();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final user = NhostManager.client.auth.currentUser;
      if (user == null) {
        setState(() {
          _error = 'يجب تسجيل الدخول لفتح المحادثة.';
          _loading = false;
        });
        return;
      }
      if (widget.conversationId.isEmpty) {
        setState(() {
          _error = 'لا يوجد معرّف محادثة في الطلب.';
          _loading = false;
        });
        return;
      }

      final query = '''
        query Conversation(\$id: uuid!) {
          chat_conversations_by_pk(id: \$id) {
            id
            account_id
            is_group
            title
            created_by
            created_at
            updated_at
            last_msg_at
            last_msg_snippet
          }
        }
      ''';
      final result = await _gql.query(
        QueryOptions(
          document: gql(query),
          variables: {'id': widget.conversationId},
          fetchPolicy: FetchPolicy.noCache,
        ),
      );
      if (result.hasException) {
        throw result.exception!;
      }
      final row = result.data?['chat_conversations_by_pk'];

      if (row == null) {
        setState(() {
          _error = 'لم أجد المحادثة أو لا تملك صلاحية الوصول.';
          _loading = false;
        });
        return;
      }

      setState(() {
        _conv = ChatConversation.fromMap(Map<String, dynamic>.from(row));
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'تعذّر فتح المحادثة: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_conv != null) {
      return ChatRoomScreen(conversation: _conv!);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('المحادثة')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error ?? 'تعذّر فتح المحادثة.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}
