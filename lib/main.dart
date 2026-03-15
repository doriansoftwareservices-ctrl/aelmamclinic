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
import 'package:aelmamclinic/utils/network_error_classifier.dart';
import 'package:aelmamclinic/core/app_navigation.dart';

/*──────── مزوّدات الحالة ────────*/
import 'providers/activation_provider.dart';
import 'providers/appointment_provider.dart';
import 'providers/locale_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/repository_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';

/*──────── خدمات وودجتس عامة ────────*/
import 'services/notification_service.dart';
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
import 'l10n/app_localizations.dart';
import 'utils/notifications_helper.dart';
import 'core/backend_lock.dart';
import 'screens/offline/offline_mode_screen.dart';
import 'services/nhost_graphql_service.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'utils/app_observability.dart';
import 'utils/app_error_reporter.dart';
import 'utils/app_locale.dart';
import 'utils/l10n_extensions.dart';
import 'firebase_options.dart';
import 'phase11/background_runtime_strategy.dart';

/// هل المنصّة تدعم flutter_local_notifications؟ (Android/iOS/macOS)
bool get _pushSupported {
  try {
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
  } catch (e, st) {
    AppObservability.warn(
      scope: 'APP',
      code: ObsCode.appPlatformProbeFailed,
      message: 'push platform capability probe failed',
      flowId: AppObservability.newFlowId('app_push_supported_probe'),
      error: e,
      stackTrace: st,
    );
    return false;
  }
}

bool _f11Down = false;
bool _fullscreenToggleInFlight = false;
DateTime? _lastFullscreenToggleAt;
const Duration _fullscreenToggleCooldown = Duration(milliseconds: 350);

Future<void> _toggleFullscreen() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
  if (_fullscreenToggleInFlight) return;
  final lastToggleAt = _lastFullscreenToggleAt;
  if (lastToggleAt != null &&
      DateTime.now().difference(lastToggleAt) < _fullscreenToggleCooldown) {
    return;
  }
  _fullscreenToggleInFlight = true;
  final isFull = await windowManager.isFullScreen();
  try {
    await windowManager.setFullScreen(!isFull);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    WidgetsBinding.instance.scheduleFrame();
    if (await windowManager.isFocused() == false) {
      await windowManager.focus();
    }
  } catch (e, st) {
    dev.log(
      'F11 fullscreen toggle failed',
      name: 'WINDOW',
      error: e,
      stackTrace: st,
    );
  } finally {
    _lastFullscreenToggleAt = DateTime.now();
    _fullscreenToggleInFlight = false;
  }
}

bool _isNetworkErrorMessage(String message) {
  return NetworkErrorClassifier.isTransportLikeMessage(message);
}

bool _isServerUnavailableMessage(String message) {
  return NetworkErrorClassifier.isServerUnavailableLikeMessage(message);
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
        AppConstants.debugLog('Data root: ${dataRoot.path}', tag: 'PATHS');
      } catch (e, st) {
        AppObservability.warn(
          scope: 'APP',
          code: ObsCode.appDataRootInitFailed,
          message: 'failed to switch current directory to app data root',
          flowId: AppObservability.newFlowId('app_data_root_switch'),
          error: e,
          stackTrace: st,
        );
      }
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
      } catch (e, st) {
        AppObservability.warn(
          scope: 'APP',
          code: ObsCode.appDataRootInitFailed,
          message: 'failed to create app data root',
          flowId: AppObservability.newFlowId('app_data_root_create'),
          error: e,
          stackTrace: st,
        );
      }
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
            unawaited(_toggleFullscreen());
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
      final isServer = _isServerUnavailableMessage(raw);
      final flowId = AppObservability.newFlowId('app_flutter_error');
      AppObservability.error(
        scope: 'APP',
        code: ObsCode.appFlutterError,
        message: 'Unhandled FlutterError captured',
        flowId: flowId,
        context: {
          'isNetworkError': isNet,
          'isServerUnavailable': isServer,
        },
        error: details.exception,
        stackTrace: details.stack,
      );
      final msg = isServer
          ? 'تعذر الوصول إلى الخادم حاليًا. حاول مرة أخرى بعد قليل.'
          : isNet
              ? 'يبدو ان الشبكة غير مستقرة لديك'
              : 'حدث خطأ غير متوقع. تم تسجيله.';
      if (isNet || isServer) {
        AppErrorReporter.info(msg,
            error: details.exception, stack: details.stack);
      } else {
        AppErrorReporter.report(msg,
            error: details.exception, stack: details.stack);
      }
      await _logCrash(details.exceptionAsString(), details.stack.toString());
      try {
        FlutterError.presentError(details);
      } catch (e, st) {
        AppObservability.warn(
          scope: 'APP',
          code: ObsCode.appFlutterErrorPresentationFailed,
          message: 'FlutterError.presentError failed; dumping to console',
          flowId: AppObservability.newFlowId('app_flutter_present_error'),
          error: e,
          stackTrace: st,
        );
        FlutterError.dumpErrorToConsole(details);
      }
    };

    final localeProvider = LocaleProvider();
    final authProvider = AuthProvider();
    final activationProvider = ActivationProvider();
    final db = DBService.instance;

    NotificationService.attachNavigator(
      appNavigatorKey,
      chatRouteName: ChatRoomLoader.routeName,
    );
    NotificationService.setOnNotificationTap((payload, response) async {
      final normalized = payload?.trim().toLowerCase() ?? '';
      if (payload != null && payload.startsWith('patient:')) {
        final parts = payload.split(':');
        final id = parts.length > 1 ? int.tryParse(parts[1]) : null;
        if (id != null) {
          try {
            final patient = await DBService.instance.getPatientById(id);
            final navigator = appNavigatorKey.currentState;
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

      if (normalized == 'plan_request' ||
          normalized == 'seat_request' ||
          normalized.startsWith('admin:')) {
        try {
          appNavigatorKey.currentState?.pushNamed('/admin');
        } catch (e) {
          debugPrint('⚠️ navigation to admin failed: $e');
        }
        return;
      }

      if (payload != null &&
          payload.isNotEmpty &&
          appNavigatorKey.currentState != null) {
        try {
          appNavigatorKey.currentState!
              .pushNamed(ChatRoomLoader.routeName, arguments: payload);
        } catch (e) {
          debugPrint('⚠️ navigation on tap failed: $e');
        }
      }
    });

    runApp(
      MultiProvider(
        providers: [
          Provider<DBService>.value(value: db),
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<LocaleProvider>.value(value: localeProvider),
          ChangeNotifierProvider<ActivationProvider>.value(
            value: activationProvider,
          ),
          ChangeNotifierProvider(
            create: (_) => AppointmentProvider(),
          ),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProxyProvider<AuthProvider, RepositoryProvider>(
            create: (_) => RepositoryProvider(),
            update: (_, auth, repo) {
              final rp = repo ?? RepositoryProvider();
              rp.scheduleAuthChange(
                auth.canEnterClinicShell ? auth.accountId : null,
              );
              return rp;
            },
          ),
          // ChatProvider يعتمد على AuthProvider
          ChangeNotifierProxyProvider2<AuthProvider, LocaleProvider,
              ChatProvider>(
            create: (_) => ChatProvider(),
            update: (_, auth, locale, previous) {
              final cp = previous ?? ChatProvider();
              final remoteBoundReady = auth.canRunRemoteBoundServices;

              if (remoteBoundReady) {
                unawaited(PushNotificationsService.instance.initForAuth(
                  accountId: auth.accountId,
                  role: auth.role,
                  languageCode: locale.languageCode,
                ));
              } else {
                unawaited(PushNotificationsService.instance.dispose());
              }

              cp.scheduleAuthSync(
                isLoggedIn: remoteBoundReady,
                accountId: remoteBoundReady ? auth.accountId : null,
                role: remoteBoundReady ? auth.role : null,
                isSuperAdmin: remoteBoundReady && auth.isSuperAdmin,
              );

              return cp;
            },
          ),
        ],
        child: const MyApp(),
      ),
    );

    unawaited(_bootstrapRuntimeAfterRunApp(
      localeProvider: localeProvider,
      authProvider: authProvider,
      db: db,
    ));
  }, (error, stack) async {
    debugPrint("Zoned error: $error\n$stack");
    final raw = error.toString();
    final isNet = _isNetworkErrorMessage(raw);
    final isServer = _isServerUnavailableMessage(raw);
    final flowId = AppObservability.newFlowId('app_zoned_error');
    AppObservability.error(
      scope: 'APP',
      code: ObsCode.appZonedError,
      message: 'Unhandled zone error captured',
      flowId: flowId,
      context: {
        'isNetworkError': isNet,
        'isServerUnavailable': isServer,
      },
      error: error,
      stackTrace: stack,
    );
    final msg = isServer
        ? 'تعذر الوصول إلى الخادم حاليًا. حاول مرة أخرى بعد قليل.'
        : isNet
            ? 'يبدو ان الشبكة غير مستقرة لديك'
            : 'حدث خطأ غير متوقع. تم تسجيله.';
    if (isNet || isServer) {
      AppErrorReporter.info(msg, error: error, stack: stack);
    } else {
      AppErrorReporter.report(msg, error: error, stack: stack);
    }
    await _logCrash(error.toString(), stack.toString());
  });
}

Future<void> _bootstrapRuntimeAfterRunApp({
  required LocaleProvider localeProvider,
  required AuthProvider authProvider,
  required DBService db,
}) async {
  final flowId = AppObservability.newFlowId('app_runtime_bootstrap');
  try {
    unawaited(NetworkStatusService.instance.start());

    await Future.wait([
      _initializeFirebaseBootstrap(),
      localeProvider.ready,
      db.database,
    ]);

    final prefs = await SharedPreferences.getInstance();
    await _purgeLegacyRememberedSecrets(prefs);

    await Future.wait([
      authProvider.init(),
      _initializeLocalNotifications(localeProvider: localeProvider),
    ]);
  } catch (e, st) {
    AppObservability.error(
      scope: 'APP',
      code: ObsCode.appRuntimeBootstrapFailed,
      message: 'post-runApp runtime bootstrap failed',
      flowId: flowId,
      error: e,
      stackTrace: st,
    );
    AppErrorReporter.report(
      'تعذرت بعض تهيئات التطبيق عند الإقلاع.',
      error: e,
      stack: st,
    );
  }
}

Future<void> _initializeFirebaseBootstrap() async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
    return;
  }
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(
    PushNotificationsService.firebaseMessagingBackgroundHandler,
  );
}

Future<void> _initializeLocalNotifications({
  required LocaleProvider localeProvider,
}) async {
  final decision = resolveBackgroundRuntimeDecision(
    pushSupported: _pushSupported,
    isAndroid: !kIsWeb && Platform.isAndroid,
    isIos: !kIsWeb && Platform.isIOS,
  );
  AppObservability.info(
    scope: 'PUSH',
    code: ObsCode.pushBackgroundStrategySelected,
    message: 'background runtime strategy selected',
    flowId: AppObservability.newFlowId('push_background_strategy'),
    context: {
      'mode': decision.mode.name,
      'supportsTerminatedPush': decision.supportsTerminatedPush,
      'requiresBatteryOptimizationPrompt':
          decision.requiresBatteryOptimizationPrompt,
    },
  );
  if (!_pushSupported) {
    debugPrint('🔕 Notifications disabled on this platform.');
    return;
  }

  await _requestNotificationPermission();
  await NotificationService().initialize();
  await NotificationsHelper.instance.init();

  if (!kDebugMode) {
    return;
  }

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      if (NotificationService().isReady) {
        await NotificationService().showChatNotification(
          id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
          title: NotificationService().translateRaw('اختبار إشعار الدردشة'),
          body: NotificationService().translateRaw(
            'لو وصلك هذا التنبيه فالقناة تعمل والصوت مضبوط',
            languageCode: localeProvider.languageCode,
          ),
          payload: 'TEST_CONV_ID',
        );
      }
    } catch (e, st) {
      AppObservability.warn(
        scope: 'APP',
        code: ObsCode.appDebugNotificationFailed,
        message: 'debug notification probe failed',
        flowId: AppObservability.newFlowId('app_debug_notification'),
        error: e,
        stackTrace: st,
      );
    }
  });
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
    final localeProvider = context.watch<LocaleProvider>();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => context.tr('app_name'),
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppErrorReporter.messengerKey,
      locale: localeProvider.locale,
      supportedLocales: AppLocale.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeProvider.themeMode,
      builder: (ctx, child) {
        if (child == null) {
          return const SizedBox.shrink();
        }
        return ActivationListener(
          child: AuthGuardListener(
            child: ResponsiveFrame(
              key: ValueKey(localeProvider.languageCode),
              child: child,
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

    if (!activation.isReady || !auth.isInitComplete) {
      return const _StartupBootstrapScreen();
    }

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
    if (auth.isSuperAdmin) {
      return auth.canEnterRemoteAdminShell
          ? const AdminDashboardScreen()
          : const LoginScreen();
    }
    return auth.canEnterClinicShell
        ? const StatisticsOverviewScreen()
        : const LoginScreen();
  }
}

class _StartupBootstrapScreen extends StatelessWidget {
  const _StartupBootstrapScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              'جاري تهيئة التطبيق...',
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
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
    final prefs = await SharedPreferences.getInstance();
    final l10n = await AppLocalizations.load(
      AppLocale.localeFromCode(prefs.getString(LocaleProvider.prefsKey)),
    );
    if (status.isDenied || status.isRestricted) {
      final result = await Permission.notification.request();
      if (result.isDenied) {
        await ToastUtils.show(l10n.tr('notif_permission_required'));
      } else if (result.isPermanentlyDenied) {
        await ToastUtils.show(l10n.tr('notif_permission_open_settings'));
        openAppSettings();
      }
    }
  } catch (e, st) {
    AppObservability.warn(
      scope: 'APP',
      code: ObsCode.appNotificationPermissionFailed,
      message: 'notification permission request failed',
      flowId: AppObservability.newFlowId('app_notification_permission'),
      error: e,
      stackTrace: st,
    );
  }
}

Future<void> _purgeLegacyRememberedSecrets(SharedPreferences prefs) async {
  if (prefs.containsKey('auth.remember_pass')) {
    await prefs.remove('auth.remember_pass');
  }
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final user = NhostManager.client.auth.currentUser;
      if (user == null) {
        setState(() {
          _error = context.tr('chat_loader_login_required');
          _loading = false;
        });
        return;
      }
      if (widget.conversationId.isEmpty) {
        setState(() {
          _error = context.tr('chat_loader_missing_conversation_id');
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
          _error = context.tr('chat_loader_not_found');
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
        _error = context.tr(
          'chat_loader_open_failed',
          params: {'reason': e},
        );
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
      appBar: AppBar(title: Text(context.tr('chat_loader_title'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error ?? context.tr('chat_loader_fallback_error'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}
