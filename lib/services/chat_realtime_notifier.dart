// lib/services/chat_realtime_notifier.dart
//
// ChatRealtimeNotifier (Nhost GraphQL)
// - إشعارات محلية للرسائل الجديدة مع احترام الكتم
// - بثّات ticks للقوائم والمشاركين + تمرير أحداث الرسائل للواجهة
//
// الاستخدام:
//   ChatRealtimeNotifier.instance.start(accountId: accId, myUid: uid);

import 'dart:async';

import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';
import 'nhost_graphql_service.dart';

class ChatRealtimeNotifier {
  ChatRealtimeNotifier._() {
    _gql = NhostGraphqlService.client;
    NhostGraphqlService.buildNotifier().addListener(_onClientRefresh);
  }
  static final ChatRealtimeNotifier instance = ChatRealtimeNotifier._();

  GraphQLClient _gql = NhostGraphqlService.client;

  final _conversationsCtrl = StreamController<void>.broadcast();
  final _participantsCtrl = StreamController<void>.broadcast();
  final _messageEventCtrl = StreamController<Map<String, dynamic>>.broadcast();

  Stream<void> get conversationsTicks => _conversationsCtrl.stream;
  Stream<void> get participantsTicks => _participantsCtrl.stream;
  Stream<Map<String, dynamic>> get messageEvents => _messageEventCtrl.stream;

  String? _myUid;

  final Set<String> _convIds = <String>{};
  final Set<String> _seenMsgIds = <String>{};
  static const int _seenCap = 6000;

  SharedPreferences? _sp;
  bool _started = false;

  StreamSubscription<QueryResult>? _messageSub;
  StreamSubscription<QueryResult>? _participantsSub;

  void _onClientRefresh() {
    _gql = NhostGraphqlService.client;
    if (!_started) return;
    _messageSub?.cancel();
    _participantsSub?.cancel();
    _messageSub = null;
    _participantsSub = null;
    unawaited(_loadConversationIds());
    _startParticipantsSubscription();
    _startMessageSubscription();
  }

  Future<void> start({
    required String? accountId,
    required String? myUid,
  }) async {
    final _ = accountId; // reserved for future account-level filtering
    _myUid = (myUid?.trim().isEmpty == true) ? null : myUid;

    if (_myUid == null) {
      _started = false;
      return;
    }

    _sp ??= await SharedPreferences.getInstance();

    try {
      await NotificationService().initialize();
    } catch (_) {}

    await _loadConversationIds();
    _startParticipantsSubscription();
    _startMessageSubscription();

    _started = true;
  }

  Future<void> stop() async {
    _started = false;
    await _messageSub?.cancel();
    await _participantsSub?.cancel();
    _messageSub = null;
    _participantsSub = null;
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

  String _activeKey(String uid) => 'chp:$uid:active';
  String _lastReadKey(String uid, String cid) => 'chp:$uid:$cid:last_read_at';

  Future<void> setActiveConversation(String? conversationId) async {
    final uid = _myUid;
    if (uid == null) return;
    _sp ??= await SharedPreferences.getInstance();
    if (conversationId == null || conversationId.trim().isEmpty) {
      await _sp!.remove(_activeKey(uid));
      return;
    }
    await _sp!.setString(_activeKey(uid), conversationId);
  }

  Future<void> setLastRead(String conversationId, DateTime at) async {
    final uid = _myUid;
    if (uid == null || conversationId.trim().isEmpty) return;
    _sp ??= await SharedPreferences.getInstance();
    await _sp!.setString(
      _lastReadKey(uid, conversationId),
      at.toUtc().toIso8601String(),
    );
  }

  DateTime? _readLastRead(String uid, String cid) {
    final raw = _sp?.getString(_lastReadKey(uid, cid));
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> _loadConversationIds() async {
    final uid = _myUid;
    if (uid == null || uid.isEmpty) {
      _convIds.clear();
      return;
    }
    try {
      final query = '''
        query MyConversationIds(\$uid: uuid!) {
          chat_participants(where: {user_uid: {_eq: \$uid}}) {
            conversation_id
          }
        }
      ''';
      final data = await _gql.query(
        QueryOptions(
          document: gql(query),
          variables: {'uid': uid},
          fetchPolicy: FetchPolicy.noCache,
        ),
      );
      final rows = (data.data?['chat_participants'] as List?) ?? const [];
      _convIds
        ..clear()
        ..addAll(
          rows
              .whereType<Map>()
              .map((e) => (e['conversation_id'] ?? '').toString())
              .where((c) => c.isNotEmpty),
        );
    } catch (_) {
      _convIds.clear();
    }
  }

  void _startParticipantsSubscription() {
    final uid = _myUid;
    if (uid == null) return;
    _participantsSub?.cancel();
    final subDoc = '''
      subscription MyParticipants(\$uid: uuid!) {
        chat_participants(where: {user_uid: {_eq: \$uid}}) {
          conversation_id
        }
      }
    ''';
    _participantsSub = _gql
        .subscribe(
      SubscriptionOptions(
        document: gql(subDoc),
        variables: {'uid': uid},
        fetchPolicy: FetchPolicy.noCache,
      ),
    )
        .listen((result) async {
      if (result.hasException) return;
      final rows = (result.data?['chat_participants'] as List?) ?? const [];
      _convIds
        ..clear()
        ..addAll(
          rows
              .whereType<Map>()
              .map((e) => (e['conversation_id'] ?? '').toString())
              .where((c) => c.isNotEmpty),
        );
      if (!_participantsCtrl.isClosed) _participantsCtrl.add(null);
      if (!_conversationsCtrl.isClosed) _conversationsCtrl.add(null);
    });
  }

  void _startMessageSubscription() {
    _messageSub?.cancel();
    final subDoc = '''
      subscription LatestMessages {
        chat_messages(
          where: {deleted: {_neq: true}},
          order_by: {created_at: desc},
          limit: 50
        ) {
          id
          conversation_id
          sender_uid
          sender_email
          kind
          body
          text
          created_at
          deleted
        }
      }
    ''';
    _messageSub = _gql
        .subscribe(
          SubscriptionOptions(
            document: gql(subDoc),
            fetchPolicy: FetchPolicy.noCache,
          ),
        )
        .listen(_handleMessageBatch);
  }

  void _handleMessageBatch(QueryResult result) {
    if (!_started || result.hasException) return;
    final rows = (result.data?['chat_messages'] as List?) ?? const [];
    for (final raw in rows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      _handleMessageRow(row);
    }
  }

  void _handleMessageRow(Map<String, dynamic> row) {
    final cid = (row['conversation_id'] ?? '').toString();
    if (cid.isEmpty || (_convIds.isNotEmpty && !_convIds.contains(cid))) {
      return;
    }

    if (!_messageEventCtrl.isClosed) {
      _messageEventCtrl.add({'new': row});
    }
    if (!_conversationsCtrl.isClosed) {
      _conversationsCtrl.add(null);
    }

    if (row['deleted'] == true) return;

    final uid = _myUid;
    if (uid != null && uid.isNotEmpty) {
      final sender = (row['sender_uid'] ?? '').toString();
      if (sender == uid) return;
    }

    final active = _sp?.getString(_activeKey(uid ?? '')) ?? '';
    if (active.isNotEmpty && active == cid) return;

    final createdAt = DateTime.tryParse(
          (row['created_at'] ?? '').toString(),
        )?.toUtc() ??
        DateTime.now().toUtc();
    final lastRead = (uid == null || uid.isEmpty)
        ? null
        : _readLastRead(uid, cid);
    if (lastRead != null && !createdAt.isAfter(lastRead)) return;

    final id = (row['id'] ?? '').toString();
    if (id.isEmpty || _seenMsgIds.contains(id)) return;
    _seenMsgIds.add(id);
    _pruneSeenIfNeeded();

    final muted = _sp?.getBool(_muteKey(uid ?? '', cid)) ?? false;
    if (muted) return;

    final kind = (row['kind']?.toString() ?? 'text').toLowerCase();
    final bodyRaw = (row['body'] ?? row['text'] ?? '').toString().trim();
    final senderEmail = (row['sender_email']?.toString() ?? '').trim();

    final title = senderEmail.isNotEmpty
        ? 'لديك رسالة من $senderEmail'
        : 'لديك رسالة جديدة';

    final body =
        (kind == 'image') ? '📷 صورة' : (bodyRaw.isEmpty ? 'رسالة' : bodyRaw);

    final nid = id.hashCode & 0x7fffffff;

    try {
      NotificationService().showChatNotification(
          id: nid, title: title, body: body, payload: cid);
    } catch (_) {}
  }

  void _pruneSeenIfNeeded({bool force = false}) {
    if (force || _seenMsgIds.length > _seenCap) {
      final keep = _seenMsgIds.toList()
        ..sort()
        ..removeRange(0, (_seenMsgIds.length / 2).floor());
      _seenMsgIds
        ..clear()
        ..addAll(keep);
    }
  }
}
