import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:gql/ast.dart';

import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/services/chat_realtime_notifier.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/notification_service.dart';
import 'package:aelmamclinic/local/chat_local_store.dart';
import 'package:aelmamclinic/utils/app_locale.dart';
import 'package:aelmamclinic/utils/app_observability.dart';
import 'package:aelmamclinic/firebase_options.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

class PushNotificationsService {
  PushNotificationsService._();
  static final PushNotificationsService instance = PushNotificationsService._();

  bool _initialized = false;
  StreamSubscription<String>? _tokenSub;
  String? _lastSyncedToken;
  bool _initialMessageHandled = false;
  String? _boundSessionKey;
  String? _pendingSessionKey;
  Future<void>? _initInFlight;
  String? _boundAccountId;
  String? _boundRole;
  String _boundLanguageCode = AppLocale.defaultLanguageCode;
  bool _supportsLocaleColumn = true;
  static final Set<String> _handledMessageKeys = <String>{};
  static final List<String> _handledMessageOrder = <String>[];
  static const int _maxHandledMessageKeys = 64;

  String _newPushFlow(String label) =>
      AppObservability.newFlowId('push_$label');

  Map<String, Object?> _pushContext([Map<String, Object?>? extra]) {
    return <String, Object?>{
      'accountId': _boundAccountId,
      'role': _boundRole,
      'languageCode': _boundLanguageCode,
      'initialized': _initialized,
      ...?extra,
    };
  }

  void _pushWarn(
    String code,
    String message, {
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    AppObservability.warn(
      scope: 'PUSH',
      code: code,
      message: message,
      flowId: flowId,
      context: _pushContext(context),
      error: error,
      stackTrace: stackTrace,
    );
  }

  String _tokenTail(String? token) {
    final value = token?.trim() ?? '';
    if (value.isEmpty) return '';
    return value.length <= 8 ? value : value.substring(value.length - 8);
  }

  bool _isDuplicateFirebaseInitError(Object error) {
    final text = '$error'.toLowerCase();
    return text.contains('duplicate-app') ||
        text.contains('already exists') ||
        text.contains('already initialized');
  }

  static bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @pragma('vm:entry-point')
  static Future<void> firebaseMessagingBackgroundHandler(
    RemoteMessage message,
  ) async {
    if (!kIsWeb) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    await NotificationService().initialize();
    await _handleMessage(message, fromBackground: true);
  }

  Future<void> initForAuth({
    required String? accountId,
    required String? role,
    required String? languageCode,
  }) async {
    final normalizedLanguageCode = AppLocale.normalize(languageCode);
    final sessionKey = _sessionKey(accountId: accountId, role: role);
    if (_initialized &&
        _boundSessionKey == sessionKey &&
        _boundLanguageCode == normalizedLanguageCode) {
      return;
    }
    if (_initInFlight != null && _pendingSessionKey == sessionKey) {
      await _initInFlight;
      if (_boundLanguageCode != normalizedLanguageCode) {
        await syncLocale(languageCode: normalizedLanguageCode);
      }
      return;
    }
    _pendingSessionKey = sessionKey;
    final future = _initForAuthInternal(
      accountId: accountId,
      role: role,
      languageCode: normalizedLanguageCode,
      sessionKey: sessionKey,
    );
    _initInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_initInFlight, future)) {
        _initInFlight = null;
      }
      if (_pendingSessionKey == sessionKey) {
        _pendingSessionKey = null;
      }
    }
  }

  Future<void> _initForAuthInternal({
    required String? accountId,
    required String? role,
    required String languageCode,
    required String sessionKey,
  }) async {
    if (!_isMobile) return;
    _boundAccountId = accountId;
    _boundRole = role;
    _boundLanguageCode = AppLocale.normalize(languageCode);
    if (_initialized) {
      await _syncToken(
        accountId: accountId,
        role: role,
        languageCode: _boundLanguageCode,
      );
      await _handleInitialMessageIfNeeded();
      _boundSessionKey = sessionKey;
      return;
    }

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e, st) {
      if (!_isDuplicateFirebaseInitError(e)) {
        _pushWarn(
          ObsCode.pushFirebaseInitFailed,
          'Firebase.initializeApp failed during push init',
          flowId: _newPushFlow('firebase_init'),
          error: e,
          stackTrace: st,
        );
      }
    }

    final messaging = FirebaseMessaging.instance;
    await messaging.setAutoInitEnabled(true);
    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    FirebaseMessaging.onMessage.listen((message) async {
      await NotificationService().initialize();
      await _handleMessage(message);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) async {
      await _handleMessage(message, opened: true);
    });

    _tokenSub = messaging.onTokenRefresh.listen((token) async {
      final flowId = _newPushFlow('token_refresh');
      final previous = _lastSyncedToken;
      try {
        final upserted = await _upsertToken(
          token,
          accountId: _boundAccountId,
          role: _boundRole,
          languageCode: _boundLanguageCode,
        );
        if (!upserted) {
          return;
        }
        if (previous != null && previous.isNotEmpty && previous != token) {
          try {
            await _deactivateToken(previous);
          } catch (e, st) {
            _pushWarn(
              ObsCode.pushTokenRefreshDeactivateFailed,
              'previous token deactivation failed during token refresh',
              flowId: flowId,
              context: {
                'previousTokenTail': _tokenTail(previous),
                'nextTokenTail': _tokenTail(token),
              },
              error: e,
              stackTrace: st,
            );
          }
        }
      } catch (e, st) {
        _pushWarn(
          ObsCode.pushTokenRefreshUpsertFailed,
          'token upsert failed during token refresh',
          flowId: flowId,
          context: {'tokenTail': _tokenTail(token)},
          error: e,
          stackTrace: st,
        );
      }
    });

    await _syncToken(
      accountId: accountId,
      role: role,
      languageCode: _boundLanguageCode,
    );
    await _handleInitialMessageIfNeeded();
    _initialized = true;
    _boundSessionKey = sessionKey;
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
    _lastSyncedToken = null;
    _initialized = false;
    _boundSessionKey = null;
    _pendingSessionKey = null;
    _initInFlight = null;
    _boundAccountId = null;
    _boundRole = null;
    _boundLanguageCode = AppLocale.defaultLanguageCode;
  }

  Future<void> syncLocale({required String languageCode}) async {
    final normalized = AppLocale.normalize(languageCode);
    _boundLanguageCode = normalized;
    if (!_isMobile) return;
    final inFlight = _initInFlight;
    if (inFlight != null) {
      await inFlight;
    }
    if (!_initialized) return;
    await _syncToken(
      accountId: _boundAccountId,
      role: _boundRole,
      languageCode: normalized,
    );
  }

  Future<void> deactivateCurrentToken() async {
    if (!_isMobile) return;
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e, st) {
      if (!_isDuplicateFirebaseInitError(e)) {
        _pushWarn(
          ObsCode.pushFirebaseInitFailed,
          'Firebase.initializeApp failed before deactivateCurrentToken',
          flowId: _newPushFlow('deactivate_current_token'),
          error: e,
          stackTrace: st,
        );
      }
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) return;
    await _deactivateToken(token);
  }

  static Future<void> _handleMessage(
    RemoteMessage message, {
    bool fromBackground = false,
    bool opened = false,
  }) async {
    if (!_registerHandledMessage(
      message,
      opened: opened,
      fromBackground: fromBackground,
    )) {
      return;
    }
    final notifier = NotificationService();
    String localize(String raw) => notifier.translateRaw(raw);
    final data = message.data;
    final type = (data['type'] ?? '').toString();
    final title = (data['title'] ?? message.notification?.title ?? '')
        .toString();
    final body = (data['body'] ?? message.notification?.body ?? '').toString();
    final payload = (data['payload'] ?? data['conversation_id'] ?? '')
        .toString();

    if (type == 'patient') {
      final patientId = int.tryParse('${data['patient_id'] ?? '0'}') ?? 0;
      final patientName = (data['patient_name'] ?? '').toString();
      if (opened) {
        await NotificationService.dispatchPayloadTap('patient:$patientId');
        return;
      }
      await NotificationService().showPatientAssignmentNotification(
        patientId: patientId,
        patientName: patientName,
      );
      return;
    }

    if (type == 'plan_request') {
      final effectivePayload = payload.isEmpty ? 'admin:plan_request' : payload;
      if (opened) {
        await NotificationService.dispatchPayloadTap(effectivePayload);
        return;
      }
      final nid = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
      await NotificationService().showAdminNotification(
        id: nid,
        title: title.isEmpty ? localize('طلب ترقية جديد') : title,
        body: body.isEmpty ? localize('تم استلام طلب ترقية جديد') : body,
        payload: effectivePayload,
      );
      return;
    }

    if (type == 'seat_request') {
      final effectivePayload = payload.isEmpty ? 'admin:seat_request' : payload;
      if (opened) {
        await NotificationService.dispatchPayloadTap(effectivePayload);
        return;
      }
      final nid = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
      await NotificationService().showAdminNotification(
        id: nid,
        title: title.isEmpty ? localize('طلب مقعد موظف إضافي') : title,
        body: body.isEmpty ? localize('تم إرسال طلب إضافة موظف إضافي') : body,
        payload: effectivePayload,
      );
      return;
    }

    // الافتراضي: رسالة دردشة
    if (payload.isNotEmpty) {
      try {
        final uid = NhostManager.client.auth.currentUser?.id ?? '';
        if (uid.isNotEmpty) {
          final archived = await ChatLocalStore.instance.isArchivedForUser(
            payload,
            uid,
          );
          if (archived) return;
        }
      } catch (e, st) {
        AppObservability.warn(
          scope: 'PUSH',
          code: ObsCode.pushArchiveLookupFailed,
          message: 'archived conversation lookup failed during push routing',
          flowId: AppObservability.newFlowId('push_archive_lookup'),
          context: {
            'payload': payload,
            'fromBackground': fromBackground,
            'opened': opened,
          },
          error: e,
          stackTrace: st,
        );
      }
    }
    if (opened) {
      await NotificationService.dispatchPayloadTap(payload);
      return;
    }

    final rt = ChatRealtimeNotifier.instance;
    final activeConversationId = rt.activeConversationId?.trim() ?? '';
    if (!fromBackground &&
        payload.isNotEmpty &&
        activeConversationId == payload) {
      return;
    }
    if (!fromBackground &&
        payload.isNotEmpty &&
        rt.isStarted &&
        rt.isTrackingConversation(payload)) {
      return;
    }

    final nid = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
    await NotificationService().showChatNotification(
      id: nid,
      title: title.isEmpty ? localize('رسالة جديدة') : title,
      body: body.isEmpty ? localize('رسالة') : body,
      payload: payload,
      threadKey: payload,
    );
  }

  Future<void> _syncToken({
    required String? accountId,
    String? role,
    required String languageCode,
  }) async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) return;
    await _upsertToken(
      token,
      accountId: accountId,
      role: role,
      languageCode: languageCode,
    );
  }

  Future<bool> _upsertToken(
    String token, {
    required String? accountId,
    String? role,
    required String languageCode,
  }) async {
    final user = NhostManager.client.auth.currentUser;
    if (user == null) return false;
    final acc = accountId ?? await ActiveAccountStore.readAccountId();
    final gql = NhostGraphqlService.client;
    final normalizedLanguageCode = AppLocale.normalize(languageCode);

    const mutation = r'''
      mutation UpsertPushToken($token: String!, $uid: uuid!, $acc: uuid, $role: String, $platform: String!, $locale: String!) {
        insert_push_device_tokens_one(
          object: {
            token: $token,
            user_uid: $uid,
            account_id: $acc,
            role: $role,
            platform: $platform,
            locale_code: $locale,
            is_active: true
          },
          on_conflict: {
            constraint: push_device_tokens_token_key,
            update_columns: [user_uid, account_id, role, platform, locale_code, is_active, updated_at]
          }
        ) {
          id
        }
      }
    ''';

    const legacyMutation = r'''
      mutation UpsertPushTokenLegacy($token: String!, $uid: uuid!, $acc: uuid, $role: String, $platform: String!) {
        insert_push_device_tokens_one(
          object: {
            token: $token,
            user_uid: $uid,
            account_id: $acc,
            role: $role,
            platform: $platform,
            is_active: true
          },
          on_conflict: {
            constraint: push_device_tokens_token_key,
            update_columns: [user_uid, account_id, role, platform, is_active, updated_at]
          }
        ) {
          id
        }
      }
    ''';

    final platform = Platform.isAndroid ? 'android' : 'ios';
    try {
      final variables = {
        'token': token,
        'uid': user.id,
        'acc': (acc != null && acc.trim().isNotEmpty) ? acc : null,
        'role': role,
        'platform': platform,
        'locale': normalizedLanguageCode,
      };
      final mutationVariables = Map<String, dynamic>.from(variables);
      if (!_supportsLocaleColumn) {
        mutationVariables.remove('locale');
      }
      final res = await gql.mutate(
        MutationOptions(
          document: gql_ast(_supportsLocaleColumn ? mutation : legacyMutation),
          variables: mutationVariables,
        ),
      );
      if (res.hasException) {
        if (_supportsLocaleColumn &&
            _containsMissingLocaleColumn(res.exception)) {
          _supportsLocaleColumn = false;
          final fallback = await gql.mutate(
            MutationOptions(
              document: gql_ast(legacyMutation),
              variables: Map<String, dynamic>.from(variables)..remove('locale'),
            ),
          );
          if (fallback.hasException) {
            _pushWarn(
              ObsCode.pushTokenUpsertFailed,
              'push token upsert failed after locale fallback',
              flowId: _newPushFlow('upsert_token'),
              context: {
                'tokenTail': _tokenTail(token),
                'localeSupported': _supportsLocaleColumn,
              },
              error: fallback.exception,
            );
            return false;
          }
        } else {
          _pushWarn(
            ObsCode.pushTokenUpsertFailed,
            'push token upsert failed',
            flowId: _newPushFlow('upsert_token'),
            context: {
              'tokenTail': _tokenTail(token),
              'localeSupported': _supportsLocaleColumn,
            },
            error: res.exception,
          );
          return false;
        }
      }
      _lastSyncedToken = token;
      return true;
    } catch (e, st) {
      _pushWarn(
        ObsCode.pushTokenUpsertFailed,
        'push token upsert threw unexpectedly',
        flowId: _newPushFlow('upsert_token'),
        context: {
          'tokenTail': _tokenTail(token),
          'localeSupported': _supportsLocaleColumn,
        },
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  Future<void> _deactivateToken(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return;
    final gql = NhostGraphqlService.client;
    const mutation = r'''
      mutation DeactivatePushToken($token: String!) {
        update_push_device_tokens(
          where: {token: {_eq: $token}}
          _set: {is_active: false}
        ) {
          affected_rows
        }
      }
    ''';
    try {
      final res = await gql.mutate(
        MutationOptions(
          document: gql_ast(mutation),
          variables: {'token': trimmed},
        ),
      );
      if (res.hasException) {
        _pushWarn(
          ObsCode.pushTokenDeactivateFailed,
          'push token deactivate failed',
          flowId: _newPushFlow('deactivate_token'),
          context: {'tokenTail': _tokenTail(trimmed)},
          error: res.exception,
        );
        return;
      }
      if (_lastSyncedToken == trimmed) {
        _lastSyncedToken = null;
      }
    } catch (e, st) {
      _pushWarn(
        ObsCode.pushTokenDeactivateFailed,
        'push token deactivate threw unexpectedly',
        flowId: _newPushFlow('deactivate_token'),
        context: {'tokenTail': _tokenTail(trimmed)},
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _handleInitialMessageIfNeeded() async {
    if (!_isMobile || _initialMessageHandled) return;
    _initialMessageHandled = true;
    try {
      final message = await FirebaseMessaging.instance.getInitialMessage();
      if (message == null) return;
      await _handleMessage(message, opened: true);
    } catch (e, st) {
      _pushWarn(
        ObsCode.pushInitialMessageFailed,
        'initial FCM message handling failed',
        flowId: _newPushFlow('initial_message'),
        error: e,
        stackTrace: st,
      );
    }
  }

  String _sessionKey({required String? accountId, required String? role}) {
    final acc = accountId?.trim() ?? '';
    final normalizedRole = role?.trim().toLowerCase() ?? '';
    return '$acc|$normalizedRole';
  }

  bool _containsMissingLocaleColumn(OperationException? exception) {
    final text = '${exception ?? ''}'.toLowerCase();
    return text.contains('locale_code') &&
        (text.contains('field') ||
            text.contains('column') ||
            text.contains('unexpected'));
  }

  static bool _registerHandledMessage(
    RemoteMessage message, {
    required bool opened,
    required bool fromBackground,
  }) {
    final payload =
        (message.data['payload'] ??
                message.data['conversation_id'] ??
                message.messageId ??
                '')
            .toString()
            .trim();
    final sentAt = message.sentTime?.millisecondsSinceEpoch ?? 0;
    final route = opened ? 'open' : 'display';
    final source = fromBackground ? 'bg' : 'fg';
    final key =
        '$route|$source|${message.messageId ?? payload}|$sentAt|${message.data['type'] ?? ''}';
    if (_handledMessageKeys.contains(key)) {
      return false;
    }
    _handledMessageKeys.add(key);
    _handledMessageOrder.add(key);
    while (_handledMessageOrder.length > _maxHandledMessageKeys) {
      final removed = _handledMessageOrder.removeAt(0);
      _handledMessageKeys.remove(removed);
    }
    return true;
  }
}

DocumentNode gql_ast(String doc) => gql(doc);
