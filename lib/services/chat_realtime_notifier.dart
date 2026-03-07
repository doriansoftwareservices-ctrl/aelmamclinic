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
  final Map<String, _ParticipantPrefs> _convPrefs =
      <String, _ParticipantPrefs>{};
  final Map<String, DateTime> _localLastRead = <String, DateTime>{};
  Future<bool> Function(String messageId)? messageKnownCheck;
  final Set<String> _seenMsgIds = <String>{};
  static const int _seenCap = 6000;

  bool _started = false;
  String? _activeConversationId;

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
    _convPrefs.clear();
    _localLastRead.clear();
    _activeConversationId = null;
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

  Future<void> setMuted(String conversationId, bool muted) async {
    final uid = _myUid;
    if (uid == null) return;
    await _updateParticipantPrefs(
      conversationId,
      uid,
      muted: muted,
    );
  }

  Future<bool> isMuted(String conversationId) async {
    final prefs = _convPrefs[conversationId];
    return prefs?.muted ?? false;
  }

  Future<bool> toggleMuted(String conversationId) async {
    final curr = await isMuted(conversationId);
    await setMuted(conversationId, !curr);
    return !curr;
  }

  Future<void> setActiveConversation(String? conversationId) async {
    if (conversationId == null || conversationId.trim().isEmpty) {
      _activeConversationId = null;
      return;
    }
    _activeConversationId = conversationId;
  }

  Future<void> setLastRead(String conversationId, DateTime at) async {
    final uid = _myUid;
    if (uid == null || conversationId.trim().isEmpty) return;
    _localLastRead[conversationId] = at.toUtc();
    await _updateParticipantPrefs(
      conversationId,
      uid,
      lastReadAt: at.toUtc(),
    );
  }

  void setLocalLastRead(String conversationId, DateTime at) {
    if (conversationId.trim().isEmpty) return;
    final prev = _localLastRead[conversationId];
    final next = at.toUtc();
    if (prev == null || next.isAfter(prev)) {
      _localLastRead[conversationId] = next;
    }
  }

  void setLocalLastReads(Map<String, DateTime?> reads) {
    for (final entry in reads.entries) {
      final ts = entry.value;
      if (ts != null) {
        setLocalLastRead(entry.key, ts);
      }
    }
  }

  Future<void> _loadConversationIds() async {
    final uid = _myUid;
    if (uid == null || uid.isEmpty) {
      _convIds.clear();
      _convPrefs.clear();
      return;
    }
    try {
      final query = '''
        query MyConversationIds(\$uid: uuid!) {
          chat_participants(where: {user_uid: {_eq: \$uid}}) {
            conversation_id
            muted
            last_read_at
            archived
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
      _convPrefs
        ..clear()
        ..addEntries(
          rows.whereType<Map>().map((row) {
            final cid = (row['conversation_id'] ?? '').toString();
            return MapEntry(cid, _ParticipantPrefs.fromRow(row));
          }).where((e) => e.key.isNotEmpty),
        );
    } catch (_) {
      _convIds.clear();
      _convPrefs.clear();
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
          muted
          last_read_at
          archived
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
      final prevIds = Set<String>.from(_convIds);
      _convIds
        ..clear()
        ..addAll(
          rows
              .whereType<Map>()
              .map((e) => (e['conversation_id'] ?? '').toString())
              .where((c) => c.isNotEmpty),
        );
      _convPrefs
        ..clear()
        ..addEntries(
          rows.whereType<Map>().map((row) {
            final cid = (row['conversation_id'] ?? '').toString();
            return MapEntry(cid, _ParticipantPrefs.fromRow(row));
          }).where((e) => e.key.isNotEmpty),
        );
      if (!_setsEqual(prevIds, _convIds)) {
        _startMessageSubscription();
      }
      if (!_participantsCtrl.isClosed) _participantsCtrl.add(null);
      if (!_conversationsCtrl.isClosed) _conversationsCtrl.add(null);
    });
  }

  void _startMessageSubscription() {
    _messageSub?.cancel();
    if (_convIds.isEmpty) {
      _messageSub = null;
      return;
    }
    final subDoc = '''
      subscription LatestMessages(\$convIds: [uuid!]!) {
        chat_messages(
          where: {deleted: {_neq: true}, conversation_id: {_in: \$convIds}},
          order_by: {created_at: desc},
          limit: 500
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
            variables: {'convIds': _convIds.toList()},
            fetchPolicy: FetchPolicy.noCache,
          ),
        )
        .listen(_handleMessageBatch);
  }

  bool _setsEqual(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }

  void _handleMessageBatch(QueryResult result) {
    if (!_started || result.hasException) return;
    final rows = (result.data?['chat_messages'] as List?) ?? const [];
    for (final raw in rows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      unawaited(_handleMessageRow(row));
    }
  }

  Future<void> _handleMessageRow(Map<String, dynamic> row) async {
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

    final active = _activeConversationId ?? '';
    if (active.isNotEmpty && active == cid) return;

    final createdAt = DateTime.tryParse(
          (row['created_at'] ?? '').toString(),
        )?.toUtc() ??
        DateTime.now().toUtc();
    final serverLastRead = _convPrefs[cid]?.lastReadAt;
    final localLastRead = _localLastRead[cid];
    final effectiveLastRead = (serverLastRead == null)
        ? localLastRead
        : (localLastRead == null
            ? serverLastRead
            : (localLastRead.isAfter(serverLastRead)
                ? localLastRead
                : serverLastRead));
    if (effectiveLastRead != null && !createdAt.isAfter(effectiveLastRead)) {
      return;
    }

    final id = (row['id'] ?? '').toString();
    if (id.isEmpty || _seenMsgIds.contains(id)) return;
    if (messageKnownCheck != null) {
      try {
        final known = await messageKnownCheck!(id);
        if (known) return;
      } catch (_) {}
    }
    _seenMsgIds.add(id);
    _pruneSeenIfNeeded();

    final prefs = _convPrefs[cid];
    if (prefs?.muted == true) return;
    if (prefs?.archived == true) return;

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

  Future<void> _updateParticipantPrefs(
    String conversationId,
    String uid, {
    bool? muted,
    DateTime? lastReadAt,
  }) async {
    if (conversationId.trim().isEmpty) return;
    final mutation = '''
      mutation UpdateParticipant(\$cid: uuid!, \$uid: uuid!, \$set: chat_participants_set_input!) {
        update_chat_participants(
          where: {conversation_id: {_eq: \$cid}, user_uid: {_eq: \$uid}},
          _set: \$set
        ) {
          affected_rows
        }
      }
    ''';
    final set = <String, dynamic>{};
    if (muted != null) set['muted'] = muted;
    if (lastReadAt != null) {
      set['last_read_at'] = lastReadAt.toUtc().toIso8601String();
    }
    if (set.isEmpty) return;
    try {
      await _gql.mutate(MutationOptions(
        document: gql(mutation),
        variables: {'cid': conversationId, 'uid': uid, 'set': set},
        fetchPolicy: FetchPolicy.noCache,
      ));
    } catch (_) {}

    final prev = _convPrefs[conversationId] ?? _ParticipantPrefs();
    _convPrefs[conversationId] = prev.copyWith(
      muted: muted,
      lastReadAt: lastReadAt,
    );
  }
}

class _ParticipantPrefs {
  final bool muted;
  final bool archived;
  final DateTime? lastReadAt;

  const _ParticipantPrefs({
    this.muted = false,
    this.archived = false,
    this.lastReadAt,
  });

  static _ParticipantPrefs fromRow(Map row) {
    final muted = row['muted'] == true;
    final archived = row['archived'] == true || row['archived'] == 1;
    final lastReadRaw = row['last_read_at']?.toString();
    final lastReadAt =
        (lastReadRaw == null || lastReadRaw.isEmpty) ? null : DateTime.tryParse(lastReadRaw)?.toUtc();
    return _ParticipantPrefs(
      muted: muted,
      archived: archived,
      lastReadAt: lastReadAt,
    );
  }

  _ParticipantPrefs copyWith({
    bool? muted,
    bool? archived,
    DateTime? lastReadAt,
  }) {
    return _ParticipantPrefs(
      muted: muted ?? this.muted,
      archived: archived ?? this.archived,
      lastReadAt: lastReadAt ?? this.lastReadAt,
    );
  }
}
