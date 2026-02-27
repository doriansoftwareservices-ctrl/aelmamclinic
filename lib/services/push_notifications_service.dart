import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:gql/ast.dart';

import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/notification_service.dart';
import 'package:aelmamclinic/local/chat_local_store.dart';
import 'package:aelmamclinic/firebase_options.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

class PushNotificationsService {
  PushNotificationsService._();
  static final PushNotificationsService instance =
      PushNotificationsService._();

  bool _initialized = false;
  StreamSubscription<String>? _tokenSub;

  static bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @pragma('vm:entry-point')
  static Future<void> firebaseMessagingBackgroundHandler(
      RemoteMessage message) async {
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
  }) async {
    if (!_isMobile) return;
    if (_initialized) {
      await _syncToken(accountId: accountId, role: role);
      return;
    }

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (_) {
      // قد تكون Firebase جاهزة
    }

    final messaging = FirebaseMessaging.instance;
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
      await _upsertToken(token, accountId: accountId, role: role);
    });

    await _syncToken(accountId: accountId, role: role);
    _initialized = true;
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
    _initialized = false;
  }

  static Future<void> _handleMessage(RemoteMessage message,
      {bool fromBackground = false, bool opened = false}) async {
    final data = message.data;
    final type = (data['type'] ?? '').toString();
    final title =
        (data['title'] ?? message.notification?.title ?? '').toString();
    final body =
        (data['body'] ?? message.notification?.body ?? '').toString();
    final payload = (data['payload'] ?? data['conversation_id'] ?? '').toString();

    if (type == 'patient') {
      final patientId = int.tryParse('${data['patient_id'] ?? '0'}') ?? 0;
      final patientName = (data['patient_name'] ?? '').toString();
      await NotificationService().showPatientAssignmentNotification(
        patientId: patientId,
        patientName: patientName,
      );
      return;
    }

    if (type == 'plan_request') {
      final nid = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
      await NotificationService().showAdminNotification(
        id: nid,
        title: title.isEmpty ? 'طلب ترقية جديد' : title,
        body: body.isEmpty ? 'تم استلام طلب ترقية جديد' : body,
        payload: payload,
      );
      return;
    }

    if (type == 'seat_request') {
      final nid = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
      await NotificationService().showAdminNotification(
        id: nid,
        title: title.isEmpty ? 'طلب مقعد موظف إضافي' : title,
        body: body.isEmpty ? 'تم إرسال طلب إضافة موظف إضافي' : body,
        payload: payload,
      );
      return;
    }

    // الافتراضي: رسالة دردشة
    if (payload.isNotEmpty) {
      try {
        final uid = NhostManager.client.auth.currentUser?.id ?? '';
        if (uid.isNotEmpty) {
          final archived = await ChatLocalStore.instance
              .isArchivedForUser(payload, uid);
          if (archived) return;
        }
      } catch (_) {}
    }
    final nid = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
    await NotificationService().showChatNotification(
      id: nid,
      title: title.isEmpty ? 'رسالة جديدة' : title,
      body: body.isEmpty ? 'رسالة' : body,
      payload: payload,
      threadKey: payload,
    );
  }

  Future<void> _syncToken({required String? accountId, String? role}) async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) return;
    await _upsertToken(token, accountId: accountId, role: role);
  }

  Future<void> _upsertToken(String token,
      {required String? accountId, String? role}) async {
    final user = NhostManager.client.auth.currentUser;
    if (user == null) return;
    final acc = accountId ?? await ActiveAccountStore.readAccountId();
    final gql = NhostGraphqlService.client;

    const mutation = r'''
      mutation UpsertPushToken($token: String!, $uid: uuid!, $acc: uuid, $role: String, $platform: String!) {
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
            update_columns: [account_id, role, platform, is_active, updated_at]
          }
        ) {
          id
        }
      }
    ''';

    final platform = Platform.isAndroid ? 'android' : 'ios';
    try {
      final res = await gql.mutate(
        MutationOptions(
          document: gql_ast(mutation),
          variables: {
            'token': token,
            'uid': user.id,
            'acc': (acc != null && acc.trim().isNotEmpty) ? acc : null,
            'role': role,
            'platform': platform,
          },
        ),
      );
      if (res.hasException) {
        dev.log('push token upsert failed',
            error: res.exception, name: 'PushNotifications');
      }
    } catch (e) {
      dev.log('push token upsert failed', error: e, name: 'PushNotifications');
    }
  }
}

DocumentNode gql_ast(String doc) => gql(doc);
