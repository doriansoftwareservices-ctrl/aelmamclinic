// lib/services/chat_realtime_notifier.dart
//
// ChatRealtimeNotifier
// - قناة Realtime واحدة عبر RealtimeHub (بدون PostgREST .stream())
// - إشعارات محلية للرسائل الجديدة من الآخرين مع احترام الكتم
// - بثّات ticks للقوائم والمشاركين + تمرير أحداث الرسائل للغرفة
// - تجنّب اللقطة الأولية الثقيلة التي سببت statement timeout
//
// المتطلبات:
//   - NotificationService جاهزة
//   - RealtimeHub مفعّل (الملف: lib/services/realtime_hub.dart)
// الاستخدام:
//   ChatRealtimeNotifier.instance.start(accountId: accId, myUid: uid);

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_service.dart';
import 'realtime_hub.dart';

class ChatRealtimeNotifier {
  ChatRealtimeNotifier._();
  static final ChatRealtimeNotifier instance = ChatRealtimeNotifier._();

  final SupabaseClient _sb = Supabase.instance.client;
  final RealtimeHub _hub = RealtimeHub.instance;

  // بثّات مبسطة لواجهة المستخدم
  final _conversationsCtrl = StreamController<void>.broadcast();
  final _participantsCtrl = StreamController<void>.broadcast();
  final _messageEventCtrl = StreamController<PostgresChangePayload>.broadcast();

  Stream<void> get conversationsTicks => _conversationsCtrl.stream;
  Stream<void> get participantsTicks => _participantsCtrl.stream;
  Stream<PostgresChangePayload> get messageEvents => _messageEventCtrl.stream;

  // فلاتر
  String? _accountId;
  String? _myUid;

  // مجموعة المحادثات التي أنا طرف فيها
  final Set<String> _convIds = <String>{};

  // منع تكرار الإشعارات
  final Set<String> _seenMsgIds = <String>{};
  static const int _seenCap = 6000;

  SharedPreferences? _sp;
  bool _started = false;

  // ---------------------------------------------------------
  // تحكم
  // ---------------------------------------------------------

  Future<void> start({
    required String? accountId,
    required String? myUid,
  }) async {
    _accountId = (accountId?.trim().isEmpty == true) ? null : accountId;
    _myUid = (myUid?.trim().isEmpty == true) ? null : myUid;

    if (_myUid == null) {
      _started = false;
      return;
    }

    // تهيئة التخزين المحلي للإعدادات (الكتم)
    _sp ??= await SharedPreferences.getInstance();

    // تهيئة خدمة الإشعارات عند الحاجة
    try {
      await NotificationService().initialize();
    } catch (_) {}

    // تحميل المحادثات المبدئية
    await _loadConversationIds();

    // الاشتراك عبر Hub بقناة واحدة
    _hub.ensureSubscribed(
      accountId: _accountId,
      myUid: _myUid,
      onConversationsChanged: _onConversationsChanged,
      onParticipantsChanged: _onParticipantsChanged,
      onMessageChanged: _onMessageChanged,
    );

    _started = true;
  }

  Future<void> stop() async {
    _started = false;
    _hub.close();
    _convIds.clear();
    _pruneSeenIfNeeded(force: true);
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _conversationsCtrl.close();
    } catch (_) {}
    try {
      await _participantsCtrl.close();
    } catch (_) {}
    try {
      await _messageEventCtrl.close();
    } catch (_) {}
  }

  // ---------------------------------------------------------
  // كتم محادثة
  // ---------------------------------------------------------

  String _muteKey(String uid, String cid) => 'chp:$uid:$cid:muted';

  Future<void> setMuted(String conversationId, bool muted) async {
    final uid = _myUid;
    if (uid == null) return;
    _sp ??= await SharedPreferences.getInstance();
    await _sp!.setBool(_muteKey(uid, conversationId), muted);
  }

  Future<bool> isMuted(String conversationId) async {
    final uid = _myUid;
    if (uid == null) return false;
    _sp ??= await SharedPreferences.getInstance();
    return _sp!.getBool(_muteKey(uid, conversationId)) ?? false;
  }

  Future<bool> toggleMuted(String conversationId) async {
    final curr = await isMuted(conversationId);
    await setMuted(conversationId, !curr);
    return !curr;
  }

  // ---------------------------------------------------------
  // ردود أفعال القناة
  // ---------------------------------------------------------

  void _onConversationsChanged() {
    if (!_started) return;
    if (!_conversationsCtrl.isClosed) _conversationsCtrl.add(null);
  }

  Future<void> _onParticipantsChanged() async {
    if (!_started) return;
    await _loadConversationIds();
    if (!_participantsCtrl.isClosed) _participantsCtrl.add(null);
  }

  void _onMessageChanged(PostgresChangePayload payload) {
    if (!_started) return;

    // مرّر الحدث للغرفة
    if (!_messageEventCtrl.isClosed) {
      _messageEventCtrl.add(payload);
    }

    // إشعار محلي على INSERT فقط
    if (payload.eventType != PostgresChangeEvent.insert) return;

    final Map<String, dynamic> row =
        (payload.newRecord as Map<String, dynamic>?) ??
            const <String, dynamic>{};

    final cid = (row['conversation_id'] ?? '').toString();
    if (cid.isEmpty || !_convIds.contains(cid)) return;

    // تجاهل المحذوف
    if (row['deleted'] == true) return;

    // تجاهل رسائلي
    final uid = _myUid ?? _sb.auth.currentUser?.id;
    if (uid != null && uid.isNotEmpty) {
      final sender = (row['sender_uid'] ?? '').toString();
      if (sender == uid) return;
    }

    // منع التكرار
    final id = (row['id'] ?? '').toString();
    if (id.isEmpty || _seenMsgIds.contains(id)) return;
    _seenMsgIds.add(id);
    _pruneSeenIfNeeded();

    // احترام الكتم
    final muted = _sp?.getBool(_muteKey(uid ?? '', cid)) ?? false;
    if (muted) return;

    // إعداد عنوان ونص الإشعار
    final kind = (row['kind']?.toString() ?? 'text').toLowerCase();
    final bodyRaw = (row['body']?.toString() ?? '').trim();
    final senderEmail = (row['sender_email']?.toString() ?? '').trim();

    final title = senderEmail.isNotEmpty
        ? 'لديك رسالة من $senderEmail'
        : 'لديك رسالة جديدة';

    final body =
        (kind == 'image') ? '📷 صورة' : (bodyRaw.isEmpty ? 'رسالة' : bodyRaw);

    final nid = id.hashCode & 0x7fffffff;

    // إطلاق الإشعار
    try {
      NotificationService().showChatNotification(
          id: nid, title: title, body: body, payload: cid);
    } catch (_) {}
  }

  // ---------------------------------------------------------
  // داخلي
  // ---------------------------------------------------------

  Future<void> _loadConversationIds() async {
    final uid = _myUid ?? _sb.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) {
      _convIds.clear();
      return;
    }
    try {
      final rows = await _sb
          .from('chat_participants')
          .select('conversation_id')
          .eq('user_uid', uid);

      _convIds
        ..clear()
        ..addAll((rows as List)
            .whereType<Map<String, dynamic>>()
            .map((e) => (e['conversation_id'] ?? '').toString())
            .where((c) => c.isNotEmpty));
    } catch (_) {
      _convIds.clear();
    }
  }

  void _pruneSeenIfNeeded({bool force = false}) {
    if (force || _seenMsgIds.length > _seenCap) {
      _seenMsgIds.clear();
    }
  }

  // أدوات تشخيص
  void debugPrintState() {
    debugPrint(
        '[ChatRealtimeNotifier] started=$_started filters: acc=$_accountId, uid=$_myUid convs=${_convIds.length}');
    _hub.debugChannels();
  }
}
