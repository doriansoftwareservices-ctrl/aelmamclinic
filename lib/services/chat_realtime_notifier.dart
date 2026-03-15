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

import 'package:aelmamclinic/phase6/chat_reliability.dart';
import 'package:aelmamclinic/utils/app_observability.dart';
import 'package:aelmamclinic/utils/logger.dart';

import 'notification_service.dart';
import 'nhost_graphql_service.dart';

class ChatRealtimeNotifier {
  ChatRealtimeNotifier._() {
    _gql = NhostGraphqlService.client;
    NhostGraphqlService.buildNotifier().addListener(_onClientRefresh);
  }
  static final ChatRealtimeNotifier instance = ChatRealtimeNotifier._();

  static const ChatRetryPolicy _kRestartPolicy = ChatRetryPolicy(
    baseDelay: Duration(seconds: 2),
    maxDelay: Duration(seconds: 30),
  );

  GraphQLClient _gql = NhostGraphqlService.client;

  final _conversationsCtrl = StreamController<void>.broadcast();
  final _participantsCtrl = StreamController<void>.broadcast();
  final _messageEventCtrl = StreamController<Map<String, dynamic>>.broadcast();

  Stream<void> get conversationsTicks => _conversationsCtrl.stream;
  Stream<void> get participantsTicks => _participantsCtrl.stream;
  Stream<Map<String, dynamic>> get messageEvents => _messageEventCtrl.stream;

  String? _myUid;
  String? _accountId;

  final Set<String> _convIds = <String>{};
  final Map<String, _ParticipantPrefs> _convPrefs =
      <String, _ParticipantPrefs>{};
  final Map<String, DateTime> _localLastRead = <String, DateTime>{};
  Future<bool> Function(String messageId)? messageKnownCheck;
  final Set<String> _seenMsgIds = <String>{};
  static const int _seenCap = 6000;

  bool _started = false;
  String? _activeConversationId;
  String? _sessionKey;
  int _sessionGeneration = 0;
  int _restartAttempt = 0;
  Timer? _restartTimer;

  StreamSubscription<QueryResult>? _messageSub;
  StreamSubscription<QueryResult>? _participantsSub;

  String _newFlow(String label) => AppObservability.newFlowId('chat_rt_$label');

  Map<String, Object?> _context([Map<String, Object?>? extra]) {
    return <String, Object?>{
      'uid': _myUid,
      'accountId': _accountId,
      'started': _started,
      'conversationCount': _convIds.length,
      'restartAttempt': _restartAttempt,
      ...?extra,
    };
  }

  void _warn(
    String code,
    String message, {
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    AppObservability.warn(
      scope: 'CHAT_RT',
      code: code,
      message: message,
      flowId: flowId,
      context: _context(context),
      error: error,
      stackTrace: stackTrace,
    );
    log.w(
      message,
      tag: 'CHAT_RT',
      data: {
        'uid': _safeUid(_myUid),
        'account_id': _accountId ?? '',
        ...?context,
        if (error != null) 'error': '$error',
      },
      st: stackTrace,
    );
  }

  void _info(
    String code,
    String message, {
    String? flowId,
    Map<String, Object?>? context,
  }) {
    AppObservability.info(
      scope: 'CHAT_RT',
      code: code,
      message: message,
      flowId: flowId,
      context: _context(context),
    );
    log.i(
      message,
      tag: 'CHAT_RT',
      data: {
        'uid': _safeUid(_myUid),
        'account_id': _accountId ?? '',
        ...?context,
      },
    );
  }

  void _onClientRefresh() {
    _gql = NhostGraphqlService.client;
    if (!_started) return;
    _scheduleRestart('client_refresh');
  }

  Future<void> start({
    required String? accountId,
    required String? myUid,
  }) async {
    final normalizedUid =
        (myUid?.trim().isEmpty == true) ? null : myUid?.trim();
    final normalizedAccountId =
        (accountId?.trim().isEmpty == true) ? null : accountId?.trim();
    final nextSessionKey =
        '${normalizedUid ?? ''}|${normalizedAccountId ?? ''}';
    if (_started &&
        _sessionKey == nextSessionKey &&
        normalizedUid == _myUid &&
        normalizedAccountId == _accountId) {
      return;
    }

    if (_started) {
      await stop();
    }

    if (normalizedUid == null) {
      await stop();
      return;
    }
    if (!hasBoundChatAccount(normalizedAccountId)) {
      _myUid = normalizedUid;
      _accountId = normalizedAccountId;
      _warn(
        ObsCode.chatAccountScopeRequired,
        'chat realtime start blocked because account scope is missing',
        flowId: _newFlow('account_scope_required'),
      );
      await stop();
      return;
    }

    _myUid = normalizedUid;
    _accountId = normalizedAccountId;
    _sessionKey = nextSessionKey;
    _started = true;
    _restartAttempt = 0;
    _restartTimer?.cancel();
    _restartTimer = null;
    _sessionGeneration += 1;
    final generation = _sessionGeneration;

    try {
      await NotificationService().initialize();
    } catch (error, st) {
      _warn(
        ObsCode.chatRealtimeSubscriptionFailed,
        'notification service initialization failed during chat realtime start',
        flowId: _newFlow('notification_init'),
        error: error,
        stackTrace: st,
      );
    }

    await _loadConversationIds(generation: generation);
    if (!_started || generation != _sessionGeneration) return;
    _startParticipantsSubscription(generation: generation);
    if (_convIds.isNotEmpty) {
      _startMessageSubscription(generation: generation);
    }

    _info(
      ObsCode.chatStateTransition,
      'chat realtime started',
      flowId: _newFlow('start'),
    );
  }

  Future<void> _cancelSubscriptions() async {
    try {
      await _messageSub?.cancel();
    } catch (_) {}
    try {
      await _participantsSub?.cancel();
    } catch (_) {}
    _messageSub = null;
    _participantsSub = null;
  }

  Future<void> stop() async {
    _started = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _restartAttempt = 0;
    _sessionGeneration += 1;
    await _cancelSubscriptions();
    _convIds.clear();
    _convPrefs.clear();
    _localLastRead.clear();
    _activeConversationId = null;
    _accountId = null;
    _myUid = null;
    _sessionKey = null;
    _pruneSeenIfNeeded(force: true);
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _conversationsCtrl.close();
    } catch (error, st) {
      _warn(
        ObsCode.chatRealtimeSubscriptionFailed,
        'failed to close conversations stream controller',
        flowId: _newFlow('close_conversations_ctrl'),
        error: error,
        stackTrace: st,
      );
    }
    try {
      await _participantsCtrl.close();
    } catch (error, st) {
      _warn(
        ObsCode.chatRealtimeSubscriptionFailed,
        'failed to close participants stream controller',
        flowId: _newFlow('close_participants_ctrl'),
        error: error,
        stackTrace: st,
      );
    }
    try {
      await _messageEventCtrl.close();
    } catch (error, st) {
      _warn(
        ObsCode.chatRealtimeSubscriptionFailed,
        'failed to close message events stream controller',
        flowId: _newFlow('close_message_ctrl'),
        error: error,
        stackTrace: st,
      );
    }
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

  void _scheduleRestart(
    String reason, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!_started) return;
    final nextAttempt = _restartAttempt + 1;
    final delay = reason == 'client_refresh'
        ? Duration.zero
        : _kRestartPolicy.delayForAttempt(nextAttempt);
    if (error != null) {
      _warn(
        ObsCode.chatRealtimeSubscriptionFailed,
        'chat realtime subscription requires restart',
        flowId: _newFlow('schedule_restart'),
        context: {
          'reason': reason,
          'delayMs': delay.inMilliseconds,
          'attempt': nextAttempt,
        },
        error: error,
        stackTrace: stackTrace,
      );
    } else {
      _info(
        ObsCode.chatStateTransition,
        'chat realtime restart scheduled',
        flowId: _newFlow('schedule_restart'),
        context: {
          'reason': reason,
          'delayMs': delay.inMilliseconds,
          'attempt': nextAttempt,
        },
      );
    }

    final activeTimer = _restartTimer;
    if (activeTimer != null && activeTimer.isActive) {
      if (delay > Duration.zero) {
        return;
      }
      activeTimer.cancel();
    }

    _restartAttempt = nextAttempt;
    final generation = _sessionGeneration;
    _restartTimer = Timer(delay, () {
      _restartTimer = null;
      if (!_started || generation != _sessionGeneration) return;
      unawaited(_restartSubscriptions(reason));
    });
  }

  Future<void> _restartSubscriptions(String reason) async {
    final uid = _myUid;
    final accountId = _accountId;
    if (!_started || uid == null || !hasBoundChatAccount(accountId)) {
      return;
    }
    final generation = _sessionGeneration;
    try {
      await _cancelSubscriptions();
      await _loadConversationIds(generation: generation);
      if (!_started || generation != _sessionGeneration) return;
      _startParticipantsSubscription(generation: generation);
      if (_convIds.isNotEmpty) {
        _startMessageSubscription(generation: generation);
      }
      _restartAttempt = 0;
      _info(
        ObsCode.chatStateTransition,
        'chat realtime restart completed',
        flowId: _newFlow('restart'),
        context: {
          'reason': reason,
        },
      );
    } catch (error, st) {
      _warn(
        ObsCode.chatRealtimeRestartFailed,
        'chat realtime restart failed',
        flowId: _newFlow('restart_failed'),
        context: {
          'reason': reason,
        },
        error: error,
        stackTrace: st,
      );
      _scheduleRestart(
        'restart_failed',
        error: error,
        stackTrace: st,
      );
    }
  }

  Future<bool> _loadConversationIds({
    required int generation,
  }) async {
    final uid = _myUid;
    final accountId = _accountId;
    if (uid == null ||
        uid.isEmpty ||
        !hasBoundChatAccount(accountId) ||
        generation != _sessionGeneration) {
      _convIds.clear();
      _convPrefs.clear();
      return false;
    }
    try {
      const query = r'''
        query MyConversationIds($uid: uuid!, $accountId: uuid!) {
          chat_participants(
            where: {
              user_uid: {_eq: $uid},
              _and: [
                {_or: [{account_id: {_eq: $accountId}}, {account_id: {_is_null: true}}]},
                {_or: [{is_deleted: {_eq: false}}, {is_deleted: {_is_null: true}}]}
              ]
            }
          ) {
            conversation_id
            muted
            last_read_at
            archived
          }
        }
      ''';
      final result = await _gql.query(
        QueryOptions(
          document: gql(query),
          variables: <String, dynamic>{
            'uid': uid,
            'accountId': accountId,
          },
          fetchPolicy: FetchPolicy.noCache,
        ),
      );
      if (generation != _sessionGeneration) return false;
      if (result.hasException) {
        throw result.exception!;
      }
      final rows = (result.data?['chat_participants'] as List?) ?? const [];
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
      return true;
    } catch (error, st) {
      _convIds.clear();
      _convPrefs.clear();
      _scheduleRestart(
        'load_conversation_ids',
        error: error,
        stackTrace: st,
      );
      return false;
    }
  }

  void _startParticipantsSubscription({
    required int generation,
  }) {
    final uid = _myUid;
    final accountId = _accountId;
    if (uid == null || !hasBoundChatAccount(accountId)) return;
    _participantsSub?.cancel();
    const subDoc = r'''
      subscription MyParticipants($uid: uuid!, $accountId: uuid!) {
        chat_participants(
          where: {
            user_uid: {_eq: $uid},
            _and: [
              {_or: [{account_id: {_eq: $accountId}}, {account_id: {_is_null: true}}]},
              {_or: [{is_deleted: {_eq: false}}, {is_deleted: {_is_null: true}}]}
            ]
          }
        ) {
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
        variables: <String, dynamic>{
          'uid': uid,
          'accountId': accountId,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    )
        .listen((result) {
      if (!_started || generation != _sessionGeneration) return;
      if (result.hasException) {
        _scheduleRestart(
          'participants_payload_exception',
          error: result.exception!,
        );
        return;
      }
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
      _restartAttempt = 0;
      if (!_setsEqual(prevIds, _convIds)) {
        _startMessageSubscription(generation: generation);
      }
      if (!_participantsCtrl.isClosed) _participantsCtrl.add(null);
      if (!_conversationsCtrl.isClosed) _conversationsCtrl.add(null);
    }, onError: (Object error, StackTrace st) {
      if (!_started || generation != _sessionGeneration) return;
      _scheduleRestart(
        'participants_stream_error',
        error: error,
        stackTrace: st,
      );
    });
  }

  void _startMessageSubscription({
    required int generation,
  }) {
    _messageSub?.cancel();
    final accountId = _accountId;
    if (_convIds.isEmpty || !hasBoundChatAccount(accountId)) {
      _messageSub = null;
      return;
    }
    const subDoc = r'''
      subscription LatestMessages($convIds: [uuid!]!, $accountId: uuid!) {
        chat_messages(
          where: {
            deleted: {_neq: true},
            account_id: {_eq: $accountId},
            conversation_id: {_in: $convIds}
          },
          order_by: {created_at: desc},
          limit: 120
        ) {
          id
          account_id
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
        variables: {
          'convIds': _convIds.toList(),
          'accountId': accountId,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    )
        .listen(
      (result) => _handleMessageBatch(result, generation: generation),
      onError: (Object error, StackTrace st) {
        if (!_started || generation != _sessionGeneration) return;
        _scheduleRestart(
          'messages_stream_error',
          error: error,
          stackTrace: st,
        );
      },
    );
  }

  bool _setsEqual(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }

  void _handleMessageBatch(
    QueryResult result, {
    required int generation,
  }) {
    if (!_started || generation != _sessionGeneration) return;
    if (result.hasException) {
      _scheduleRestart(
        'messages_payload_exception',
        error: result.exception!,
      );
      return;
    }
    final rows = (result.data?['chat_messages'] as List?) ?? const [];
    for (final raw in rows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      unawaited(_handleMessageRow(row, generation: generation));
    }
  }

  Future<void> _handleMessageRow(
    Map<String, dynamic> row, {
    required int generation,
  }) async {
    if (!_started || generation != _sessionGeneration) return;
    final cid = (row['conversation_id'] ?? '').toString();
    final rowAccountId = (row['account_id'] ?? '').toString().trim();
    if (cid.isEmpty ||
        (_convIds.isNotEmpty && !_convIds.contains(cid)) ||
        (rowAccountId.isNotEmpty && rowAccountId != (_accountId ?? ''))) {
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
        if (!_started || generation != _sessionGeneration) return;
        if (known) return;
      } catch (error, st) {
        _warn(
          ObsCode.chatRealtimeSubscriptionFailed,
          'messageKnownCheck failed; falling back to local seen-set',
          flowId: _newFlow('message_known_check'),
          context: {
            'messageId': id,
            'conversationId': cid,
          },
          error: error,
          stackTrace: st,
        );
      }
    }
    _seenMsgIds.add(id);
    _pruneSeenIfNeeded();

    final prefs = _convPrefs[cid];
    if (prefs?.muted == true) return;
    if (prefs?.archived == true) return;

    final kind = (row['kind']?.toString() ?? 'text').toLowerCase();
    final bodyRaw = (row['body'] ?? row['text'] ?? '').toString().trim();
    final senderEmail = (row['sender_email']?.toString() ?? '').trim();

    final notifier = NotificationService();
    final title = senderEmail.isNotEmpty
        ? notifier.translateRaw('لديك رسالة من $senderEmail')
        : notifier.translateRaw('لديك رسالة جديدة');

    final body = (kind == 'image')
        ? notifier.translateRaw('📷 صورة')
        : (bodyRaw.isEmpty ? notifier.translateRaw('رسالة') : bodyRaw);

    final nid = id.hashCode & 0x7fffffff;

    try {
      NotificationService().showChatNotification(
        id: nid,
        title: title,
        body: body,
        payload: cid,
      );
    } catch (error, st) {
      _warn(
        ObsCode.chatRealtimeSubscriptionFailed,
        'failed to show chat notification',
        flowId: _newFlow('show_notification'),
        context: {
          'messageId': id,
          'conversationId': cid,
        },
        error: error,
        stackTrace: st,
      );
    }
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
    final mutation = r'''
      mutation UpdateParticipant($cid: uuid!, $uid: uuid!, $set: chat_participants_set_input!) {
        update_chat_participants(
          where: {conversation_id: {_eq: $cid}, user_uid: {_eq: $uid}},
          _set: $set
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
      final result = await _gql.mutate(
        MutationOptions(
          document: gql(mutation),
          variables: {'cid': conversationId, 'uid': uid, 'set': set},
          fetchPolicy: FetchPolicy.noCache,
        ),
      );
      if (result.hasException) {
        _warn(
          ObsCode.chatRealtimeSubscriptionFailed,
          'participant preferences mutation returned exception',
          flowId: _newFlow('update_participant_prefs'),
          context: {
            'conversationId': conversationId,
            'targetUid': _safeUid(uid),
          },
          error: result.exception!,
        );
      }
    } catch (error, st) {
      _warn(
        ObsCode.chatRealtimeSubscriptionFailed,
        'participant preferences mutation failed',
        flowId: _newFlow('update_participant_prefs'),
        context: {
          'conversationId': conversationId,
          'targetUid': _safeUid(uid),
        },
        error: error,
        stackTrace: st,
      );
    }

    final prev = _convPrefs[conversationId] ?? const _ParticipantPrefs();
    _convPrefs[conversationId] = prev.copyWith(
      muted: muted,
      lastReadAt: lastReadAt,
    );
  }

  String _safeUid(String? uid) {
    final value = (uid ?? '').trim();
    if (value.isEmpty) return '';
    if (value.length <= 8) return value;
    return '${value.substring(0, 8)}...';
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
    final lastReadAt = (lastReadRaw == null || lastReadRaw.isEmpty)
        ? null
        : DateTime.tryParse(lastReadRaw)?.toUtc();
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
