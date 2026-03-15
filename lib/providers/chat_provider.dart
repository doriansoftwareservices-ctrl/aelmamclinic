// lib/providers/chat_provider.dart
//
// مزوّد حالة الدردشة مع كاش محلي وتكامل Realtime عبر ChatRealtimeNotifier.
// - لا يستخدم PostgREST .stream() لقائمة الرسائل/المحادثات العامة.
// - يستمع لتيارات ChatRealtimeNotifier: محادثات/مشاركين/أحداث رسائل.
// - يبقي بث الغرفة فقط عند فتح محادثة عبر ChatService.watchMessages.
// - حماية من "used after dispose" عبر _disposed + _safeNotify.
// - ✅ تكامل AttachmentCache: عدم إعادة تنزيل الصور، وتهيئة الكاش للرسائل الظاهرة.
// - ✅ تحويل الرسائل إلى محادثات/مجموعات أخرى.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import 'package:aelmamclinic/local/chat_local_store.dart';
import 'package:aelmamclinic/models/chat_invitation.dart';
import 'package:aelmamclinic/models/chat_models.dart' as CM;
import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/phase6/chat_reliability.dart';
import 'package:aelmamclinic/services/chat_service.dart';
import 'package:aelmamclinic/services/chat_realtime_notifier.dart';
import 'package:aelmamclinic/services/attachment_cache.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';
import 'package:aelmamclinic/services/network_status_service.dart';
import 'package:aelmamclinic/utils/app_observability.dart';
import 'package:aelmamclinic/utils/logger.dart';
import 'package:aelmamclinic/utils/app_error_reporter.dart';
import 'package:aelmamclinic/utils/chat_code_utils.dart';
import 'package:aelmamclinic/utils/device_id.dart';
import 'package:aelmamclinic/l10n/raw_string_localizer.dart';

String _trChat(String raw) =>
    RawStringLocalizer.translateWithCurrentLocale(raw);

class _ChatAuthSnapshot {
  const _ChatAuthSnapshot({
    required this.isLoggedIn,
    required this.accountId,
    required this.role,
    required this.isSuperAdmin,
  });

  final bool isLoggedIn;
  final String? accountId;
  final String? role;
  final bool isSuperAdmin;
}

class ChatProvider extends ChangeNotifier {
  ChatProvider() {
    _initNetworkMonitor();
  }

  String _newChatFlow(String label) =>
      AppObservability.newFlowId('chat_$label');

  Map<String, Object?> _chatContext([Map<String, Object?>? extra]) {
    return <String, Object?>{
      'uid': currentUid,
      'accountId': _accountFilter,
      'isOnline': _isOnline,
      'isSuperAdmin': _isSuperAdmin,
      'ready': ready,
      ...?extra,
    };
  }

  void _chatWarn(
    String code,
    String message, {
    String? flowId,
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) {
    AppObservability.warn(
      scope: 'CHAT',
      code: code,
      message: message,
      flowId: flowId,
      context: _chatContext(context),
      error: error,
      stackTrace: stackTrace,
    );
  }

  CM.ChatMessage _bindMessageToActiveAccount(CM.ChatMessage message) {
    if (!hasBoundChatAccount(_accountFilter) ||
        hasBoundChatAccount(message.accountId)) {
      return message;
    }
    return message.copyWith(accountId: _accountFilter);
  }

  List<CM.ChatMessage> _bindMessagesToActiveAccount(
    Iterable<CM.ChatMessage> messages,
  ) {
    return messages.map(_bindMessageToActiveAccount).toList();
  }

  CM.ChatConversation _bindConversationToActiveAccount(
    CM.ChatConversation conversation,
  ) {
    if (!hasBoundChatAccount(_accountFilter) ||
        hasBoundChatAccount(conversation.accountId)) {
      return conversation;
    }
    return conversation.copyWith(accountId: _accountFilter);
  }

  String _requiredChatAccountId() {
    final accountId = _accountFilter?.trim() ?? '';
    if (accountId.isEmpty) {
      throw StateError('chat account scope is not bound');
    }
    return accountId;
  }

  Future<void> _persistMessages(Iterable<CM.ChatMessage> messages) {
    return _local.upsertMessages(_bindMessagesToActiveAccount(messages));
  }

  Future<void> _persistConversations(
    Iterable<CM.ChatConversation> conversations,
  ) {
    return _local.upsertConversations(
      conversations.map(_bindConversationToActiveAccount).toList(),
    );
  }

  // جداول
  static const String tableParticipants = 'chat_participants';
  static const String tableAccountUsers = 'account_users';
  static const String tableProfiles = 'profiles';
  static const String tableReads = 'chat_reads';
  static const String storageBucketChat = ChatService.attachmentsBucket;

  // نوافذ صلاحيات
  static const Duration editWindow = Duration(hours: 2);
  static const Duration deleteWindow = Duration(hours: 12);
  static const String _outboxStageDirName = 'elmam_chat_outbox';

  // خدمات
  GraphQLClient get _gql => NhostGraphqlService.client;
  final NhostStorageService _storage = NhostStorageService();
  final ChatService _chat = ChatService.instance;
  final ChatRealtimeNotifier _rt = ChatRealtimeNotifier.instance;
  final AttachmentCache _attCache = AttachmentCache.instance; // ✅
  final Map<String, ({String url, DateTime expiresAt})> _signedUrlCache = {};
  final Map<String, DateTime> _recentIncomingMessageIds = {};
  String? _deviceId;
  DateTime? _lastDeviceRegAt;
  Timer? _deviceRegTimer;
  Timer? _attachmentCleanupTimer;
  Timer? _outboxRetryTimer;

  // هوية
  String get currentUid => NhostManager.client.auth.currentUser?.id ?? '';
  String? _myEmailCache;

  // حالة عامة
  bool ready = false;
  bool busy = false;
  String? lastError;
  bool _isOnline = true;
  bool get isOnline => _isOnline;
  String? _accountFilter;
  bool _isSuperAdmin = false;
  bool _isSupportAgent = false;
  String? _bootstrapSessionKey;
  Future<void>? _bootstrapInFlight;
  _ChatAuthSnapshot? _queuedAuthSnapshot;
  bool _authSyncScheduled = false;
  String? _supportAgentUidCache;
  static const String _kSupportAgentUid = 'chat.support_agent_uid';
  static const String _kSupportConvId = 'chat.support_conversation_id';
  static const String _kSupportDisplayName = 'chat.support_display_name';
  static const String _kSupportFollowupSent = 'chat.support_followup_sent';
  bool get isSupportAgent => _isSupportAgent;

  // كاش محلي
  final ChatLocalStore _local = ChatLocalStore.instance;

  final List<CM.ChatConversation> _conversations = [];
  List<CM.ChatConversation> get conversations =>
      List.unmodifiable(_conversations);

  final List<ChatGroupInvitation> _invitations = [];
  List<ChatGroupInvitation> get invitations => List.unmodifiable(_invitations);

  final Map<String, List<ChatParticipantLocal>> _participantsByConv = {};
  final Map<String, List<CM.ChatReadState>> _readStatesByConv = {};
  final Map<String, String> _aliasByUser = {};
  final Map<String, String> _aliasCache = {};
  final Map<String, String> _displayTitleByConv = {};
  String _displayTitleForDirect(
    CM.ChatConversation conv,
    ChatParticipantLocal other, {
    String? alias,
  }) {
    final label = _displayLabelForParticipant(other, alias: alias).trim();
    if (label.isNotEmpty && label != _trChat('بدون رقم')) return label;

    final title = (conv.title ?? '').trim();
    if (title.isNotEmpty) {
      return ChatCodeUtils.isChatCode(title)
          ? ChatCodeUtils.format(title)
          : title;
    }

    final cached = _displayTitleByConv[conv.id];
    if (cached != null &&
        cached.trim().isNotEmpty &&
        cached != _trChat('بدون رقم')) {
      return cached.trim();
    }

    return label.isNotEmpty ? label : _trChat('بدون رقم');
  }

  String displayTitleOf(String conversationId) {
    final alias = aliasForConversation(conversationId);
    if (alias != null && alias.trim().isNotEmpty) return alias.trim();
    final cached = _displayTitleByConv[conversationId];
    if (cached != null && cached.trim().isNotEmpty) return cached;
    try {
      final conv = _conversations.firstWhere(
        (c) => c.id == conversationId,
        orElse: () => _conversations.isNotEmpty
            ? _conversations.first
            : CM.ChatConversation(
                id: conversationId,
                type: CM.ChatConversationType.direct,
                createdAt: DateTime.now().toUtc(),
              ),
      );
      if (conv.type == CM.ChatConversationType.direct) {
        final participants = _participantsByConv[conversationId] ??
            const <ChatParticipantLocal>[];
        if (participants.isNotEmpty) {
          final other = participants.firstWhere(
            (p) => p.userUid != currentUid,
            orElse: () => participants.first,
          );
          final label = _displayTitleForDirect(conv, other).trim();
          if (label.isNotEmpty) return label;
        }
      }
      final t = (conv.title ?? '').trim();
      if (t.isNotEmpty) return t;
    } catch (_) {}
    return _trChat('محادثة');
  }

  String? _supportConversationId;
  String _supportDisplayName = _trChat('خدمة العملاء');
  bool _supportReady = false;
  final Set<String> _supportFollowupSentSessions = <String>{};
  DateTime _bootAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  String? get supportConversationId => _supportConversationId;
  String get supportDisplayName => _supportDisplayName;
  bool isSupportConversation(String conversationId) {
    if (_supportConversationId == conversationId) return true;
    final supportUid = _supportAgentUidCache;
    if (supportUid == null || supportUid.trim().isEmpty) return false;
    final participants =
        _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[];
    if (participants.isEmpty) return false;
    return participants.any((p) => p.userUid == supportUid);
  }

  static const Set<String> _ownerRoles = {
    'owner',
    'admin',
    'owner_admin',
  };

  bool _isOwnerConversation(String conversationId) {
    final participants =
        _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[];
    if (participants.isEmpty) return false;
    for (final p in participants) {
      final role = (p.role ?? '').toLowerCase().trim();
      if (_ownerRoles.contains(role)) return true;
    }
    return false;
  }

  CM.ChatSupportStatus? supportStatusOf(String conversationId) {
    final conv = _conversations.firstWhere((c) => c.id == conversationId,
        orElse: () => CM.ChatConversation(
              id: conversationId,
              type: CM.ChatConversationType.direct,
              createdAt: DateTime.now().toUtc(),
            ));
    return conv.supportStatus;
  }

  Future<void> setSupportStatus(
    String conversationId,
    CM.ChatSupportStatus status, {
    bool syncRemote = true,
  }) async {
    if (conversationId.trim().isEmpty) return;
    final idx = _conversations.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    var c = _conversations[idx];
    if (c.supportStatus == status) return;
    c = c.copyWith(supportStatus: status);
    _conversations[idx] = c;
    _safeNotify();
    unawaited(_persistConversations([c]));
    if (syncRemote && _isOnline) {
      unawaited(
        _chat.updateConversationSupportStatus(
          conversationId: conversationId,
          status: status,
        ),
      );
    }
  }

  Future<void> _maybeSetPendingOnIncoming(
    String conversationId,
    String fromUid,
  ) async {
    if (!_isSupportAgent || !_isSuperAdmin) return;
    if (!isSupportConversation(conversationId)) return;
    if (!_isOwnerConversation(conversationId)) return;
    if (fromUid.trim().isEmpty || fromUid == currentUid) return;
    final current = supportStatusOf(conversationId);
    if (current == null ||
        current == CM.ChatSupportStatus.closed ||
        current == CM.ChatSupportStatus.responded) {
      await setSupportStatus(
        conversationId,
        CM.ChatSupportStatus.pendingReply,
      );
    }
  }

  Future<void> _maybeAdvanceToUnderReview(String conversationId) async {
    if (!_isSupportAgent) return;
    if (!isSupportConversation(conversationId)) return;
    if (!_isOwnerConversation(conversationId)) return;
    final current = supportStatusOf(conversationId);
    if (current == CM.ChatSupportStatus.pendingReply || current == null) {
      await setSupportStatus(
        conversationId,
        CM.ChatSupportStatus.underReview,
      );
    }
  }

  final Map<String, List<CM.ChatMessage>> _messagesByConv = {};
  List<CM.ChatMessage> messagesOf(String conversationId) =>
      List.unmodifiable(_messagesByConv[conversationId] ?? const []);

  int get totalUnreadCount =>
      _conversations.fold(0, (sum, c) => sum + (c.unreadCount ?? 0));

  final Map<String, DateTime?> _olderCursorByConv = {};
  final Map<String, DateTime?> _myLastReadByConv = {};
  DateTime? lastReadAtOf(String conversationId) =>
      _myLastReadByConv[conversationId];

  String? _openedConversationId;
  String? get openedConversationId => _openedConversationId;
  bool isConversationOpen(String conversationId) =>
      _openedConversationId == conversationId;

  final Map<String, Set<String>> _typingUidsByConv = {};
  Set<String> typingUids(String conversationId) =>
      _typingUidsByConv[conversationId] ?? <String>{};

  int _lastLocalSeq = 0;
  int _generateLocalSeq() {
    final now = DateTime.now().microsecondsSinceEpoch;
    if (now <= _lastLocalSeq) {
      _lastLocalSeq += 1;
    } else {
      _lastLocalSeq = now;
    }
    return _lastLocalSeq;
  }

  Future<String?> _ensureDeviceId() async {
    if (_deviceId != null && _deviceId!.trim().isNotEmpty) {
      return _deviceId;
    }
    try {
      _deviceId = await DeviceId.get();
      return _deviceId;
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatDeviceIdResolveFailed,
        'device id resolution failed for chat provider',
        flowId: _newChatFlow('device_id'),
        error: e,
        stackTrace: st,
      );
      return _deviceId;
    }
  }

  String _platformTag() {
    if (kIsWeb) return 'web';
    try {
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _ensureDeviceRegistration({bool force = false}) async {
    if (!_isOnline) return;
    final dev = await _ensureDeviceId();
    if (dev == null || dev.trim().isEmpty) return;
    final now = DateTime.now();
    if (!force && _lastDeviceRegAt != null) {
      final delta = now.difference(_lastDeviceRegAt!);
      if (delta.inMinutes < 5) return;
    }
    try {
      await _chat.registerDevice(
        deviceId: dev,
        platform: _platformTag(),
        appVersion: null,
      );
      _lastDeviceRegAt = now;
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatDeviceRegistrationFailed,
        'chat device registration failed',
        flowId: _newChatFlow('device_registration'),
        context: {
          'deviceId': dev,
          'force': force,
        },
        error: e,
        stackTrace: st,
      );
    }
  }

  void _startDeviceRegistrationTimer() {
    _deviceRegTimer?.cancel();
    if (_disposed || !_isOnline || !hasBoundChatAccount(_accountFilter)) {
      _deviceRegTimer = null;
      return;
    }
    _deviceRegTimer = Timer(const Duration(minutes: 5), () async {
      _deviceRegTimer = null;
      if (_disposed || !_isOnline || !hasBoundChatAccount(_accountFilter)) {
        return;
      }
      await _ensureDeviceRegistration();
      _startDeviceRegistrationTimer();
    });
  }

  // اشتراكات
  StreamSubscription<List<CM.ChatMessage>>? _roomMsgsSub;
  StreamSubscription<Map<String, dynamic>>? _typingSub;
  StreamSubscription<QueryResult>? _readsSub;

  // RealtimeNotifier subs
  StreamSubscription<void>? _rtConvSub;
  StreamSubscription<void>? _rtPartSub;
  StreamSubscription<Map<String, dynamic>>? _rtMsgSub;
  StreamSubscription<bool>? _netSub;

  // Anti-dup / Throttling
  bool _listLoading = false;
  int _listRev = 0;
  Timer? _listDebounce;
  bool _outboxFlushInProgress = false;
  bool _outboxFlushRequested = false;
  int _outboxRetryAttempt = 0;
  static const ChatRetryPolicy _kOutboxRetryPolicy = ChatRetryPolicy(
    baseDelay: Duration(seconds: 2),
    maxDelay: Duration(seconds: 30),
  );

  // حماية التخلص
  bool _disposed = false;
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  String _sessionKeyFor({
    required String? accountId,
    required String? role,
    required bool isSuperAdmin,
  }) {
    final uid = currentUid.trim();
    final acc = accountId?.trim() ?? '';
    final normalizedRole = role?.trim().toLowerCase() ?? '';
    return '$uid|$acc|$normalizedRole|$isSuperAdmin';
  }

  void scheduleAuthSync({
    required bool isLoggedIn,
    required String? accountId,
    required String? role,
    required bool isSuperAdmin,
  }) {
    _queuedAuthSnapshot = _ChatAuthSnapshot(
      isLoggedIn: isLoggedIn,
      accountId: accountId?.trim(),
      role: role?.trim(),
      isSuperAdmin: isSuperAdmin,
    );
    if (_authSyncScheduled) return;
    _authSyncScheduled = true;
    Future.microtask(_runQueuedAuthSync);
  }

  Future<void> _runQueuedAuthSync() async {
    final snapshot = _queuedAuthSnapshot;
    _queuedAuthSnapshot = null;
    if (_disposed || snapshot == null) {
      _authSyncScheduled = false;
      return;
    }
    try {
      if (!snapshot.isLoggedIn) {
        await _performSignedOutReset();
      } else {
        await ensureBootstrapped(
          accountId: snapshot.accountId,
          role: snapshot.role,
          isSuperAdmin: snapshot.isSuperAdmin,
        );
      }
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatRpcWarning,
        'queued chat auth sync failed',
        flowId: _newChatFlow('auth_sync'),
        context: {
          'snapshotAccountId': snapshot.accountId,
          'snapshotRole': snapshot.role,
          'snapshotIsLoggedIn': snapshot.isLoggedIn,
          'snapshotIsSuperAdmin': snapshot.isSuperAdmin,
        },
        error: e,
        stackTrace: st,
      );
      _setError(_trChat('تعذّر تهيئة الدردشة: $e'));
      _safeNotify();
    }
    if (_disposed) {
      _authSyncScheduled = false;
      return;
    }
    if (_queuedAuthSnapshot != null) {
      Future.microtask(_runQueuedAuthSync);
      return;
    }
    _authSyncScheduled = false;
  }

  Future<void> ensureBootstrapped({
    String? accountId,
    String? role,
    bool isSuperAdmin = false,
  }) async {
    if (_disposed) return;
    final key = _sessionKeyFor(
      accountId: accountId,
      role: role,
      isSuperAdmin: isSuperAdmin,
    );
    if (currentUid.isEmpty) {
      await _performSignedOutReset();
      return;
    }
    if (ready && _bootstrapSessionKey == key) {
      return;
    }
    if (_bootstrapInFlight != null && _bootstrapSessionKey == key) {
      await _bootstrapInFlight;
      return;
    }
    if (_bootstrapInFlight != null) {
      await _bootstrapInFlight;
      if (_disposed) return;
      if (ready && _bootstrapSessionKey == key) {
        return;
      }
    }

    final previousKey = _bootstrapSessionKey;
    final future = () async {
      if (previousKey != null && previousKey != key) {
        await _performSignedOutReset(notify: false, clearLocalCache: false);
      }
      await bootstrap(
        accountId: accountId,
        role: role,
        isSuperAdmin: isSuperAdmin,
      );
      if (!_disposed) {
        _bootstrapSessionKey = key;
      }
    }();

    _bootstrapSessionKey = key;
    _bootstrapInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_bootstrapInFlight, future)) {
        _bootstrapInFlight = null;
      }
    }
  }

  void onSignedOut() {
    if (_disposed) return;
    unawaited(_performSignedOutReset());
  }

  Future<void> _performSignedOutReset({
    bool notify = true,
    bool clearLocalCache = true,
  }) async {
    if (_disposed) return;
    _queuedAuthSnapshot = null;
    _bootstrapSessionKey = null;
    _bootstrapInFlight = null;
    await _cancelConversationSubscriptions();
    try {
      await _rt.stop();
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatRpcWarning,
        'chat realtime stop failed during signed-out reset',
        flowId: _newChatFlow('signed_out_rt_stop'),
        error: e,
        stackTrace: st,
      );
    }
    ready = false;
    busy = false;
    lastError = null;
    _isOnline = true;
    _isSuperAdmin = false;
    _isSupportAgent = false;
    _supportAgentUidCache = null;
    _accountFilter = null;
    _myEmailCache = null;
    _supportConversationId = null;
    _supportDisplayName = _trChat('خدمة العملاء');
    _supportReady = false;
    _openedConversationId = null;
    _recentIncomingMessageIds.clear();
    _signedUrlCache.clear();
    _conversations.clear();
    _invitations.clear();
    _messagesByConv.clear();
    _olderCursorByConv.clear();
    _myLastReadByConv.clear();
    _participantsByConv.clear();
    _readStatesByConv.clear();
    _typingUidsByConv.clear();
    _aliasByUser.clear();
    _aliasCache.clear();
    _displayTitleByConv.clear();
    _supportFollowupSentSessions.clear();
    _deviceRegTimer?.cancel();
    _deviceRegTimer = null;
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _outboxFlushInProgress = false;
    _outboxFlushRequested = false;
    _outboxRetryAttempt = 0;
    _listDebounce?.cancel();
    _listDebounce = null;
    _typingPingDebounce?.cancel();
    _typingPingDebounce = null;
    _attachmentCleanupTimer?.cancel();
    _attachmentCleanupTimer = null;
    if (clearLocalCache) {
      try {
        await _local.clearAllData();
      } catch (e, st) {
        _chatWarn(
          ObsCode.chatRpcWarning,
          'chat local cache clear failed during signed-out reset',
          flowId: _newChatFlow('signed_out_local_clear'),
          error: e,
          stackTrace: st,
        );
      }
    }
    if (notify) {
      _safeNotify();
    }
  }

  Future<void> _cancelConversationSubscriptions() async {
    try {
      await _roomMsgsSub?.cancel();
    } catch (_) {}
    _roomMsgsSub = null;
    try {
      await _typingSub?.cancel();
    } catch (_) {}
    _typingSub = null;
    try {
      await _readsSub?.cancel();
    } catch (_) {}
    _readsSub = null;
    try {
      await _rtConvSub?.cancel();
    } catch (_) {}
    _rtConvSub = null;
    try {
      await _rtPartSub?.cancel();
    } catch (_) {}
    _rtPartSub = null;
    try {
      await _rtMsgSub?.cancel();
    } catch (_) {}
    _rtMsgSub = null;
  }

  void _setError(String message) {
    final msg = message.trim();
    final lower = msg.toLowerCase();
    final isNetwork = !NetworkStatusService.instance.isOnline ||
        lower.contains('network') ||
        lower.contains('socket') ||
        lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('failed host lookup') ||
        lower.contains('semaphore timeout') ||
        lower.contains('semaphore') ||
        lower.contains('bad gateway') ||
        lower.contains('service temporarily unavailable') ||
        lower.contains('503') ||
        lower.contains('502') ||
        lower.contains('document is empty') ||
        lower.contains('responseformatexception') ||
        lower.contains('formatexception');
    lastError = isNetwork ? _trChat('يبدو ان الشبكة غير مستقرة لديك') : msg;
    if (isNetwork) {
      AppErrorReporter.info(lastError!);
    } else {
      AppErrorReporter.report(lastError!);
    }
  }

  void _scheduleConversationsRefresh() {
    _listDebounce?.cancel();
    _listDebounce = Timer(const Duration(milliseconds: 250), () async {
      if (_disposed) return;
      await refreshConversations();
    });
  }

  void _initNetworkMonitor() {
    _isOnline = NetworkStatusService.instance.isOnline;
    unawaited(NetworkStatusService.instance.start());
    _netSub?.cancel();
    _netSub = NetworkStatusService.instance.changes.listen((online) {
      if (_disposed) return;
      _isOnline = online;
      if (online) {
        unawaited(_resumeOnline());
      } else {
        unawaited(_pauseOnline());
      }
      _safeNotify();
    });
  }

  Future<void> _pauseOnline() async {
    await _cancelConversationSubscriptions();
    try {
      await _rt.stop();
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatRpcWarning,
        'chat realtime stop failed while pausing online state',
        flowId: _newChatFlow('pause_online_rt_stop'),
        error: e,
        stackTrace: st,
      );
    }
    _attachmentCleanupTimer?.cancel();
    _attachmentCleanupTimer = null;
    _deviceRegTimer?.cancel();
    _deviceRegTimer = null;
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
  }

  Future<void> _resumeOnline() async {
    if (_disposed || currentUid.isEmpty) return;
    if (!hasBoundChatAccount(_accountFilter)) return;
    await _ensureDeviceRegistration(force: true);
    _startDeviceRegistrationTimer();
    try {
      await _rt.start(accountId: _accountFilter, myUid: currentUid);
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatRealtimeRestartFailed,
        'chat realtime start failed while resuming online state',
        flowId: _newChatFlow('resume_online_rt_start'),
        error: e,
        stackTrace: st,
      );
    }
    unawaited(_loadMyConversationsAndParticipants());
    unawaited(refreshInvitations());
    if (_openedConversationId != null) {
      if (_allowRemoteHistory(_openedConversationId!)) {
        unawaited(_refreshLatestMessages(_openedConversationId!));
      }
      unawaited(_refreshReadStatesForConversation(_openedConversationId!));
      try {
        await _roomMsgsSub?.cancel();
      } catch (_) {}
      final cached = _messagesByConv[_openedConversationId!] ?? const [];
      final since = cached.isNotEmpty
          ? cached.first.createdAt
          : DateTime.now().toUtc().subtract(const Duration(seconds: 5));
      _roomMsgsSub = _chat
          .watchMessages(
        _openedConversationId!,
        since: _allowRemoteHistory(_openedConversationId!) ? null : since,
        seedFromServer: _allowRemoteHistory(_openedConversationId!),
      )
          .listen(
        (remoteList) async {
          if (_disposed) return;
          final latest = _bindMessagesToActiveAccount(remoteList);
          await _persistMessages(latest);
          if (_disposed) return;
          _mergeIncomingMessages(_openedConversationId!, latest);
          _scheduleConversationsRefresh();
          _safeNotify();
          unawaited(
            prefetchVisibleAttachments(_openedConversationId!, maxMessages: 30),
          );
          await _applyReadsToOutgoing(_openedConversationId!);
        },
      );
    }
    _requestOutboxFlush(reason: 'resume_online');
    _startAttachmentCleanupWorker();
  }

  Future<void> _loadLocalSnapshot({
    required String accountId,
  }) async {
    try {
      final localConvs = await _local.getConversations(accountId: accountId);
      if (localConvs.isEmpty) return;
      final visibleConvs = <CM.ChatConversation>[];

      final tmpParts = <String, List<ChatParticipantLocal>>{};
      final tmpReads = <String, List<CM.ChatReadState>>{};
      final tmpDisplay = <String, String>{};
      final tmpLastReadByConv = <String, DateTime?>{};

      for (final c in localConvs) {
        if (c.isDeleted || c.isGroup) {
          continue;
        }
        final boundConversation = _bindConversationToActiveAccount(c);
        final partsRaw = await _local.getParticipants(boundConversation.id);
        final parts =
            partsRaw.map((m) => ChatParticipantLocal.fromMap(m)).toList();

        final isMine = parts.any((p) => p.userUid == currentUid);
        if (!isMine && c.createdBy != currentUid) {
          // لا تعرض محادثات من مستخدمين آخرين في نفس الجهاز.
          continue;
        }

        visibleConvs.add(boundConversation);
        tmpParts[boundConversation.id] = parts;

        final reads = await _local.getReadStates(boundConversation.id);
        tmpReads[boundConversation.id] = reads;

        if (boundConversation.isGroup) {
          tmpDisplay[boundConversation.id] =
              (boundConversation.title?.trim().isNotEmpty == true)
                  ? boundConversation.title!.trim()
                  : _trChat('مجموعة');
        } else {
          final other = parts.firstWhere(
            (p) => p.userUid != currentUid,
            orElse: () => parts.isNotEmpty
                ? parts.first
                : ChatParticipantLocal.fallback(boundConversation.id),
          );
          tmpDisplay[boundConversation.id] =
              _displayTitleForDirect(boundConversation, other);
        }

        final lastRead = await _local.getLastRead(boundConversation.id);
        if (lastRead != null) {
          tmpLastReadByConv[boundConversation.id] = lastRead;
        }
      }

      visibleConvs.sort((a, b) {
        final ta = a.lastMsgAt ?? a.createdAt;
        final tb = b.lastMsgAt ?? b.createdAt;
        return tb.compareTo(ta);
      });

      _participantsByConv
        ..clear()
        ..addAll(tmpParts);
      _readStatesByConv
        ..clear()
        ..addAll(tmpReads);
      _displayTitleByConv
        ..clear()
        ..addAll(tmpDisplay);
      _myLastReadByConv
        ..clear()
        ..addAll(tmpLastReadByConv);
      _conversations
        ..clear()
        ..addAll(visibleConvs);

      _rt.setLocalLastReads(_myLastReadByConv);
      _rt.messageKnownCheck =
          (id) => _local.hasMessage(id, accountId: accountId);

      _safeNotify();
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatRpcWarning,
        'chat local snapshot load failed',
        flowId: _newChatFlow('local_snapshot'),
        context: {
          'accountId': accountId,
        },
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> _loadAliasCache() async {
    try {
      final uid = currentUid;
      if (uid.isEmpty) return;
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('chat.aliases.$uid');
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _aliasCache
          ..clear()
          ..addAll(decoded.map((k, v) => MapEntry(k.toString(), v.toString())));
      }
    } catch (_) {}
  }

  Future<void> _loadSupportFollowupSessions() async {
    try {
      final uid = currentUid;
      if (uid.isEmpty) return;
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('$_kSupportFollowupSent.$uid');
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _supportFollowupSentSessions
          ..clear()
          ..addAll(decoded.whereType<String>());
      }
    } catch (_) {}
  }

  Future<void> _persistSupportFollowupSessions() async {
    try {
      final uid = currentUid;
      if (uid.isEmpty) return;
      final sp = await SharedPreferences.getInstance();
      final list = _supportFollowupSentSessions.toList();
      const maxKeep = 500;
      final trimmed =
          list.length > maxKeep ? list.sublist(list.length - maxKeep) : list;
      await sp.setString('$_kSupportFollowupSent.$uid', jsonEncode(trimmed));
    } catch (_) {}
  }

  Future<void> _persistAliasCache() async {
    try {
      final uid = currentUid;
      if (uid.isEmpty) return;
      final sp = await SharedPreferences.getInstance();
      await sp.setString('chat.aliases.$uid', jsonEncode(_aliasCache));
    } catch (_) {}
  }

  // --------------------------------------------------------------------------
  // Bootstrap
  // --------------------------------------------------------------------------
  Future<void> bootstrap({
    String? accountId,
    String? role,
    bool isSuperAdmin = false,
  }) async {
    if (currentUid.isEmpty) {
      _setError(_trChat('لا يوجد مستخدم مسجّل الدخول.'));
      busy = false;
      _safeNotify();
      return;
    }
    busy = true;
    _safeNotify();
    try {
      _bootAt = DateTime.now().toUtc();
      await _primeMyEmail();
      await _loadSupportFollowupSessions();
      await _loadAliasCache();
      await _resolveSupportAgentCache();
      final supportUid = await _resolveSupportAgentUid();
      _isSupportAgent =
          supportUid != null && supportUid.trim() == currentUid.trim();
      final accId = accountId ??
          await fetchAccountIdForCurrentUser(isSuperAdmin: isSuperAdmin);
      final accountFilter =
          (accId == null || accId.trim().isEmpty) ? null : accId.trim();
      _accountFilter = accountFilter;
      _isSuperAdmin = isSuperAdmin;

      if (!hasBoundChatAccount(accountFilter)) {
        _setError(
            _trChat('لا يمكن تحميل المحادثات لأن الحساب الحالي غير محدد.'));
        try {
          await _rt.stop();
        } catch (e, st) {
          _chatWarn(
            ObsCode.chatRealtimeRestartFailed,
            'chat realtime stop failed while blocking unbound chat scope',
            flowId: _newChatFlow('chat_scope_block'),
            error: e,
            stackTrace: st,
          );
        }
        return;
      }

      final scopeReset = await _local.ensureSessionScope(
        buildChatStorageScopeKey(
          uid: currentUid,
          accountId: accountFilter!,
        ),
      );
      if (scopeReset) {
        _chatWarn(
          ObsCode.chatLocalScopeReset,
          'chat local scope changed; local cache was reset',
          flowId: _newChatFlow('chat_scope_reset'),
          context: {
            'accountId': accountFilter,
          },
        );
      }

      await _loadLocalSnapshot(accountId: accountFilter);

      if (_isOnline) {
        await _ensureDeviceRegistration(force: true);
        _startDeviceRegistrationTimer();
      }

      // بدء Realtime الموحّد (تجاوز في وضع Offline)
      if (_isOnline) {
        try {
          await _rt.start(accountId: accountFilter, myUid: currentUid);
        } catch (error, stackTrace) {
          debugPrint(
            'ChatProvider.bootstrap: فشل بدء Realtime: $error\n$stackTrace',
          );
          _isOnline = false;
          unawaited(_pauseOnline());
        }
      }

      // تحميل القائمة والمشاركين مبدئياً
      if (_isOnline) {
        await _loadMyConversationsAndParticipants();
        await refreshInvitations();
      }
      if (_disposed) return;

      // الاشتراك في التيارات الموحّدة
      _rtConvSub?.cancel();
      if (_isOnline) {
        _rtConvSub = _rt.conversationsTicks.listen((_) {
          if (_disposed) return;
          _scheduleConversationsRefresh();
        });
      }

      _rtPartSub?.cancel();
      if (_isOnline) {
        _rtPartSub = _rt.participantsTicks.listen((_) {
          if (_disposed) return;
          _scheduleConversationsRefresh();
        });
      }

      _rtMsgSub?.cancel();
      if (_isOnline) {
        _rtMsgSub = _rt.messageEvents.listen((payload) {
          if (_disposed) return;
          try {
            _handleMessageInsert(payload);
          } catch (e, st) {
            _chatWarn(
              ObsCode.chatRealtimeMessageInsertFailed,
              'realtime message insert handling failed',
              flowId: _newChatFlow('realtime_message_insert'),
              context: {
                'conversationId': payload['conversation_id'],
                'messageId': payload['id'],
              },
              error: e,
              stackTrace: st,
            );
          }
          _scheduleConversationsRefresh();
        });
      }

      ready = true;
      if (_isOnline) {
        _requestOutboxFlush(reason: 'bootstrap');
        _startAttachmentCleanupWorker();
      }
    } catch (e, stackTrace) {
      debugPrint(_trChat('ChatProvider.bootstrap: حدث خطأ غير متوقّع: $e'));
      debugPrint('$stackTrace');
      lastError ??= _trChat('حدث خطأ غير متوقع أثناء تجهيز المحادثات.');
      if (lastError != null) {
        AppErrorReporter.report(lastError!, error: e, stack: stackTrace);
      }
    } finally {
      busy = false;
      _safeNotify();
    }
  }

  Future<void> ensureSupportConversation({bool force = false}) async {
    if (_disposed) return;
    if (_supportReady && !force) return;
    if (_isSupportAgent) {
      _supportReady = true;
      return;
    }
    if (!_isOnline) {
      _supportReady = true;
      return;
    }

    try {
      final agent = await _chat.fetchSupportAgent();
      if (agent == null) {
        _supportReady = true;
        return;
      }

      final uid = agent['user_uid'] ?? '';
      final name = agent['display_name'] ?? _trChat('خدمة العملاء');
      if (uid.isEmpty) {
        _supportReady = true;
        return;
      }

      _supportDisplayName = name;

      final conv = await _chat.startSupportConversation();
      _supportConversationId = conv.id;
      _displayTitleByConv[conv.id] = name;
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_kSupportConvId, conv.id);
        await sp.setString(_kSupportDisplayName, name);
        if (uid.isNotEmpty) {
          await sp.setString(_kSupportAgentUid, uid);
        }
      } catch (e, st) {
        _chatWarn(
          ObsCode.chatSupportCacheWriteFailed,
          'support conversation cache write failed',
          flowId: _newChatFlow('support_cache_write'),
          context: {
            'conversationId': conv.id,
            'supportUid': uid,
          },
          error: e,
          stackTrace: st,
        );
      }
    } catch (e, st) {
      _rpcWarn('ensureSupportConversation failed', e, st);
    } finally {
      _supportReady = true;
      _safeNotify();
    }
  }

  Future<void> _resolveSupportAgentCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _supportAgentUidCache = sp.getString(_kSupportAgentUid);
      final cachedConv = sp.getString(_kSupportConvId);
      if (cachedConv != null && cachedConv.trim().isNotEmpty) {
        _supportConversationId = cachedConv.trim();
      }
      final cachedName = sp.getString(_kSupportDisplayName);
      if (cachedName != null && cachedName.trim().isNotEmpty) {
        _supportDisplayName = cachedName.trim();
      }
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatSupportCacheReadFailed,
        'support cache read failed',
        flowId: _newChatFlow('support_cache_read'),
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<String?> _resolveSupportAgentUid() async {
    if (!_isOnline) return _supportAgentUidCache;
    try {
      final agent = await _chat.fetchSupportAgent();
      if (agent == null) return _supportAgentUidCache;
      final uid = (agent['user_uid'] ?? '').toString().trim();
      if (uid.isNotEmpty) {
        _supportDisplayName =
            (agent['display_name'] ?? _trChat('خدمة العملاء')).toString();
        _supportAgentUidCache = uid;
        try {
          final sp = await SharedPreferences.getInstance();
          await sp.setString(_kSupportAgentUid, uid);
          await sp.setString(_kSupportDisplayName, _supportDisplayName);
        } catch (e, st) {
          _chatWarn(
            ObsCode.chatSupportCacheWriteFailed,
            'support agent cache write failed',
            flowId: _newChatFlow('support_agent_cache_write'),
            context: {
              'supportUid': uid,
            },
            error: e,
            stackTrace: st,
          );
        }
        return uid;
      }
    } catch (e, st) {
      _chatWarn(
        ObsCode.chatSupportAgentResolveFailed,
        'support agent resolution failed',
        flowId: _newChatFlow('support_agent_resolve'),
        error: e,
        stackTrace: st,
      );
    }
    return _supportAgentUidCache;
  }

  Future<String?> fetchAccountIdForCurrentUser(
      {bool isSuperAdmin = false}) async {
    final uid = currentUid;
    if (uid.isEmpty) return null;
    if (isSuperAdmin) return null;

    final preferred = await ActiveAccountStore.readAccountId();
    if (preferred != null && preferred.isNotEmpty) {
      return preferred;
    }

    try {
      final query = '''
        query ProfileAccount(\$id: uuid!) {
          ${tableProfiles}_by_pk(id: \$id) {
            account_id
          }
        }
      ''';
      final data = await _runQuery(query, {'id': uid});
      final row = data['${tableProfiles}_by_pk'] as Map?;
      final acc = row?['account_id']?.toString();
      if (acc != null && acc.isNotEmpty) return acc;
    } catch (e, st) {
      _rpcWarn('profiles.account_id lookup failed', e, st);
    }

    try {
      final query = '''
        query MyAccountId {
          my_account_id {
            account_id
          }
        }
      ''';
      final data = await _runQuery(query, const {});
      final rows = (data['my_account_id'] as List?) ?? const [];
      final row = rows.isNotEmpty ? rows.first as Map? : null;
      final acc = row?['account_id']?.toString() ?? '';
      if (acc.isNotEmpty && acc != 'null') return acc;
    } catch (e, st) {
      _rpcWarn('my_account_id RPC failed', e, st);
    }

    try {
      final query = '''
        query AccountUserAccount(\$uid: uuid!) {
          ${tableAccountUsers}(
            where: {user_uid: {_eq: \$uid}},
            order_by: {created_at: desc},
            limit: 1
          ) {
            account_id
          }
        }
      ''';
      final data = await _runQuery(query, {'uid': uid});
      final rows = _rowsFromData(data, tableAccountUsers);
      final acc = rows.isEmpty ? null : rows.first['account_id']?.toString();
      if (acc != null && acc.isNotEmpty) return acc;
    } catch (e, st) {
      _rpcWarn('account_users account_id lookup failed', e, st);
    }

    _rpcWarn('account_id resolution returned null',
        StateError('no account binding for $uid'));
    return null;
  }

  // Helpers
  Future<void> _primeMyEmail() async {
    final e = (NhostManager.client.auth.currentUser?.email ?? '').toLowerCase();
    if (e.isNotEmpty) {
      _myEmailCache = e;
      return;
    }
    try {
      final query = '''
        query MyEmail(\$uid: uuid!) {
          ${tableAccountUsers}(
            where: {user_uid: {_eq: \$uid}},
            order_by: {created_at: desc},
            limit: 1
          ) {
            email
          }
        }
      ''';
      final data = await _runQuery(query, {'uid': currentUid});
      final rows = _rowsFromData(data, tableAccountUsers);
      final em = (rows.isEmpty ? '' : rows.first['email']?.toString() ?? '')
          .toLowerCase();
      if (em.isNotEmpty) {
        _myEmailCache = em;
        return;
      }
    } catch (_) {}
    _myEmailCache = 'unknown@local';
  }

  String get myEmail => _myEmailCache ?? 'unknown@local';

  bool _looksLikeUuid(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    final re = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return re.hasMatch(v);
  }

  Future<String?> _resolveFileId(String bucket, String path) async {
    final trimmed = path.trim();
    if (_looksLikeUuid(trimmed)) return trimmed;
    if (bucket.trim().isEmpty) return null;
    try {
      final query = '''
        query StorageFileId(\$bucket: String!, \$name: String!) {
          files(where: {bucketId: {_eq: \$bucket}, name: {_eq: \$name}}, limit: 1) {
            id
          }
        }
      ''';
      final data = await _runQuery(query, {'bucket': bucket, 'name': trimmed});
      final rows = (data['files'] as List?) ?? const [];
      final row = rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
      final id = row?['id']?.toString();
      return (id == null || id.isEmpty) ? null : id;
    } catch (_) {
      return null;
    }
  }

  Future<String> _signedOrPublicUrl(String bucket, String path) async {
    if (AppConstants.chatPreferPublicUrls) {
      final fileId = await _resolveFileId(bucket, path);
      if (fileId != null && fileId.isNotEmpty) {
        return _storage.publicFileUrl(fileId);
      }
      return _storage.publicFileUrl(path);
    }

    final cacheKey = '$bucket|$path';
    final cached = _signedUrlCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }

    final fileId = await _resolveFileId(bucket, path);
    if (fileId != null && fileId.isNotEmpty) {
      final signed = await _storage.createSignedUrl(
        fileId,
        expiresInSeconds: AppConstants.storageSignedUrlTTLSeconds,
      );
      if (signed != null && signed.isNotEmpty) {
        final ttl = Duration(seconds: AppConstants.storageSignedUrlTTLSeconds);
        _signedUrlCache[cacheKey] = (
          url: signed,
          expiresAt: DateTime.now().add(ttl - const Duration(seconds: 30)),
        );
        return signed;
      }
      return _storage.publicFileUrl(fileId);
    }

    return _storage.publicFileUrl(path);
  }

  // --------------------------------------------------------------------------
  // تحميل قائمة محادثاتي + المشاركين (+ آخر قراءة) مع دمج ذكي:
  // - يحافظ على ظهور "أحدث رسالة" في الكرت: نُبقي lastMsgAt/snippet الأحدث بين
  //   الحالة السابقة والراجعة من السيرفر (تفادي الرجوع للخلف بسبب تأخّر التحديث).
  // --------------------------------------------------------------------------
  Future<void> _loadMyConversationsAndParticipants() async {
    final accountId = _accountFilter?.trim();
    if (!hasBoundChatAccount(accountId)) {
      _setError(_trChat('لا يمكن تحديث المحادثات بدون تحديد الحساب الحالي.'));
      return;
    }
    if (_listLoading) {
      _listRev++;
      return;
    }
    _listLoading = true;
    final myRev = ++_listRev;

    try {
      final List<CM.ConversationListItem> overview =
          (await _chat.fetchMyConversationsOverview(
        includeLastMessageText: false,
      ))
              .where(
                (item) =>
                    !item.conversation.isGroup &&
                    (item.conversation.accountId?.trim() ?? '') == accountId,
              )
              .toList();
      final convIds = overview
          .map((item) => item.conversation.id)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (convIds.isEmpty) {
        // لا تتخلص من المؤرشفة المحلية في حال لم يُعد الخادم أي محادثة.
        await _loadLocalSnapshot(accountId: accountId!);
        return;
      }

      // دفعات المشاركين
      const chunk = 100;
      final tmpParticipantsByConv = <String, List<ChatParticipantLocal>>{};

      for (var i = 0; i < convIds.length; i += chunk) {
        final end = (i + chunk > convIds.length) ? convIds.length : i + chunk;
        final slice = convIds.sublist(i, end);

        final query = '''
          query Participants(\$ids: [uuid!]!) {
            ${tableParticipants}(where: {conversation_id: {_in: \$ids}}) {
              conversation_id
              user_uid
              email
              joined_at
              nickname
              display_name
              role
              archived
              pinned
              blocked
              is_deleted
            }
          }
        ''';
        final data = await _runQuery(query, {'ids': slice});
        final partsRows = _rowsFromData(data, tableParticipants);

        for (final r in partsRows) {
          final cid = r['conversation_id']?.toString();
          if (cid == null) continue;
          final p = ChatParticipantLocal.fromMap(r);
          (tmpParticipantsByConv[cid] ??= <ChatParticipantLocal>[]).add(p);
        }
      }

      // دفعات حالات القراءة/التسليم
      final tmpReadsByConv = <String, List<CM.ChatReadState>>{};
      for (var i = 0; i < convIds.length; i += chunk) {
        final end = (i + chunk > convIds.length) ? convIds.length : i + chunk;
        final slice = convIds.sublist(i, end);
        final query = '''
          query ReadsStates(\$ids: [uuid!]!) {
            $tableReads(where: {conversation_id: {_in: \$ids}}) {
              conversation_id
              user_uid
              last_read_message_id
              last_read_at
              last_delivered_message_id
              last_delivered_at
            }
          }
        ''';
        final data = await _runQuery(query, {'ids': slice});
        final rows = _rowsFromData(data, tableReads);
        for (final r in rows) {
          final cid = r['conversation_id']?.toString();
          if (cid == null) continue;
          final st = CM.ChatReadState.fromMap(r);
          (tmpReadsByConv[cid] ??= <CM.ChatReadState>[]).add(st);
        }
      }

      final serverList = overview
          .map(
            (item) => _bindConversationToActiveAccount(
              item.conversation.copyWith(
                unreadCount: item.unreadCount,
              ),
            ),
          )
          .toList();

      // عنونة العرض
      Map<String, String> aliasByUser = {};
      try {
        aliasByUser = await _chat.fetchAliasMap();
      } catch (_) {
        aliasByUser = {};
      }
      if (_aliasCache.isNotEmpty) {
        for (final entry in _aliasCache.entries) {
          aliasByUser.putIfAbsent(entry.key, () => entry.value);
        }
      }
      final tmpDisplay = <String, String>{};
      for (final c in serverList) {
        final cid = c.id.trim();
        if (cid.isEmpty) continue;

        if (c.isGroup) {
          tmpDisplay[cid] = (c.title?.trim().isNotEmpty == true)
              ? c.title!.trim()
              : _trChat('مجموعة');
        } else {
          final parts =
              tmpParticipantsByConv[cid] ?? const <ChatParticipantLocal>[];
          final other = parts.firstWhere(
            (p) => p.userUid != currentUid,
            orElse: () => parts.isNotEmpty
                ? parts.first
                : ChatParticipantLocal.fallback(cid),
          );
          final alias = aliasByUser[other.userUid];
          tmpDisplay[cid] = _displayTitleForDirect(c, other, alias: alias);
        }
      }
      if (_supportConversationId != null) {
        tmpDisplay[_supportConversationId!] = _supportDisplayName;
      }

      final lastReadByConv = <String, DateTime?>{};
      for (final item in overview) {
        final cid = item.conversation.id;
        if (cid.isNotEmpty) {
          lastReadByConv[cid] = item.lastReadAt;
        }
      }

      // ── دمج المحادثات المؤرشفة محليًا (قد لا يعيدها السيرفر في القائمة) ──
      final serverIds = serverList.map((c) => c.id).toSet();
      final localArchived = <CM.ChatConversation>[];
      try {
        final localConvs = await _local.getConversations(accountId: accountId);
        for (final c in localConvs) {
          if (c.isDeleted || c.isGroup) continue;
          if (serverIds.contains(c.id)) continue;
          final partsRaw = await _local.getParticipants(c.id);
          final parts =
              partsRaw.map((m) => ChatParticipantLocal.fromMap(m)).toList();
          final me = parts.firstWhere(
            (p) => p.userUid == currentUid,
            orElse: () => ChatParticipantLocal.fallback(c.id),
          );
          if (me.userUid != currentUid || me.archived != true) {
            continue;
          }

          tmpParticipantsByConv[c.id] = parts;
          final reads = await _local.getReadStates(c.id);
          if (reads.isNotEmpty) {
            tmpReadsByConv[c.id] = reads;
          }
          if (!tmpDisplay.containsKey(c.id)) {
            final other = parts.firstWhere(
              (p) => p.userUid != currentUid,
              orElse: () => parts.isNotEmpty
                  ? parts.first
                  : ChatParticipantLocal.fallback(c.id),
            );
            tmpDisplay[c.id] = _displayTitleForDirect(c, other);
          }
          final lastRead = await _local.getLastRead(c.id);
          if (lastRead != null) {
            lastReadByConv[c.id] = lastRead;
          }
          localArchived.add(c);
        }
      } catch (_) {}

      // دمج مع الحالة السابقة لمنع رجوع الخلف في snippet/lastMsgAt + منع وميض unread
      final prevById = {for (final c in _conversations) c.id: c};
      final openedId = _openedConversationId;

      CM.ChatConversation _mergeConv(
        CM.ChatConversation srv,
        CM.ChatConversation? prev,
      ) {
        // حافظ على الأحدث بين server/prev
        final serverAt = srv.lastMsgAt ?? srv.createdAt;
        final prevAt = prev?.lastMsgAt ?? prev?.createdAt;
        DateTime effAt = serverAt;
        String? effSnippet = srv.lastMsgSnippet;

        if (prevAt != null && prevAt.isAfter(serverAt)) {
          effAt = prevAt;
          effSnippet = prev?.lastMsgSnippet ?? effSnippet;
        } else if ((effSnippet == null || effSnippet.trim().isEmpty) &&
            (prev?.lastMsgSnippet?.trim().isNotEmpty ?? false)) {
          // إن كان السيرفر بلا قصاصة مؤقتًا، استخدم السابقة
          effSnippet = prev!.lastMsgSnippet;
        }

        // unread يعتمد على الخادم لضمان الدقة (مع تصفير المفتوح)
        final serverUc = srv.unreadCount ?? 0;
        var uc = (openedId == srv.id) ? 0 : serverUc;
        if (uc == 0 && (prev?.unreadCount ?? 0) > 0) {
          final lr = _myLastReadByConv[srv.id];
          final prevAt = prev?.lastMsgAt ?? prev?.createdAt;
          if (lr == null || (prevAt != null && prevAt.isAfter(lr))) {
            uc = prev!.unreadCount ?? 0;
          }
        }

        final effTitle =
            (srv.title?.trim().isNotEmpty ?? false) ? srv.title : prev?.title;

        return srv.copyWith(
          lastMsgAt: effAt,
          lastMsgSnippet: effSnippet,
          unreadCount: uc,
          title: effTitle,
        );
      }

      final merged = <CM.ChatConversation>[];
      for (final c in serverList) {
        merged.add(_mergeConv(c, prevById[c.id]));
      }
      if (localArchived.isNotEmpty) {
        for (final c in localArchived) {
          if (merged.any((m) => m.id == c.id)) continue;
          merged.add(c);
        }
      }

      // ترتيب حسب الأحدث
      merged.sort((a, b) {
        final ta = a.lastMsgAt ?? a.createdAt;
        final tb = b.lastMsgAt ?? b.createdAt;
        return tb.compareTo(ta);
      });

      if (myRev != _listRev || _disposed) return;

      _aliasByUser
        ..clear()
        ..addAll(aliasByUser);
      _aliasCache
        ..clear()
        ..addAll(aliasByUser);
      unawaited(_persistAliasCache());
      _participantsByConv
        ..clear()
        ..addAll(tmpParticipantsByConv);
      _readStatesByConv
        ..clear()
        ..addAll(tmpReadsByConv);
      _displayTitleByConv
        ..clear()
        ..addAll(tmpDisplay);
      _myLastReadByConv
        ..clear()
        ..addAll(lastReadByConv);
      _conversations
        ..clear()
        ..addAll(merged);

      try {
        await _persistConversations(merged);
        final allParts = <Map<String, dynamic>>[];
        for (final entry in tmpParticipantsByConv.entries) {
          for (final p in entry.value) {
            allParts.add(p.toMap());
          }
        }
        if (allParts.isNotEmpty) {
          await _local.upsertParticipants(allParts);
        }
        final allReads = <CM.ChatReadState>[];
        for (final entry in tmpReadsByConv.entries) {
          allReads.addAll(entry.value);
        }
        if (allReads.isNotEmpty) {
          await _local.upsertReadStates(allReads);
        }
      } catch (_) {}

      _safeNotify();
    } catch (e) {
      _rpcWarn('fetchMyConversationsOverview failed', e);
    } finally {
      _listLoading = false;
    }
  }

  Future<void> refreshConversations() async {
    if (!_isOnline) {
      final accountId = _accountFilter?.trim();
      if (!hasBoundChatAccount(accountId)) return;
      await _loadLocalSnapshot(accountId: accountId!);
      return;
    }
    await _loadMyConversationsAndParticipants();
    await refreshInvitations();
  }

  CM.ChatConversation? conversationById(String id) {
    try {
      return _conversations.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> refreshInvitations() async {
    if (_disposed) return;
    if (!_isOnline) return;
    if (_invitations.isNotEmpty) {
      _invitations.clear();
      _safeNotify();
    }
  }

  String? aliasForConversation(String conversationId) {
    final participants =
        _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[];
    if (participants.isEmpty) return null;
    final other = participants.firstWhere(
      (p) => p.userUid != currentUid,
      orElse: () => participants.first,
    );
    return _aliasByUser[other.userUid];
  }

  Future<void> updateConversationAlias({
    required String conversationId,
    required String alias,
  }) async {
    final participants =
        _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[];
    if (participants.isEmpty) return;
    final other = participants.firstWhere(
      (p) => p.userUid != currentUid,
      orElse: () => participants.first,
    );
    if (other.userUid.isEmpty) return;
    final trimmed = alias.trim();
    final previousAlias = _aliasByUser[other.userUid];
    final previousCachedAlias = _aliasCache[other.userUid];
    if (trimmed.isEmpty) {
      _aliasByUser.remove(other.userUid);
      _aliasCache.remove(other.userUid);
      await _persistAliasCache();
      try {
        await _chat.removeAlias(other.userUid);
      } catch (e) {
        if (previousAlias != null && previousAlias.isNotEmpty) {
          _aliasByUser[other.userUid] = previousAlias;
        }
        if (previousCachedAlias != null && previousCachedAlias.isNotEmpty) {
          _aliasCache[other.userUid] = previousCachedAlias;
        }
        await _persistAliasCache();
        _setError(_trChat('تعذر حفظ الاسم المستعار: $e'));
        _safeNotify();
        return;
      }
    } else {
      _aliasByUser[other.userUid] = trimmed;
      _aliasCache[other.userUid] = trimmed;
      await _persistAliasCache();
      try {
        await _chat.setAlias(targetUid: other.userUid, alias: trimmed);
      } catch (e) {
        if (previousAlias == null || previousAlias.isEmpty) {
          _aliasByUser.remove(other.userUid);
        } else {
          _aliasByUser[other.userUid] = previousAlias;
        }
        if (previousCachedAlias == null || previousCachedAlias.isEmpty) {
          _aliasCache.remove(other.userUid);
        } else {
          _aliasCache[other.userUid] = previousCachedAlias;
        }
        await _persistAliasCache();
        _setError(_trChat('تعذر حفظ الاسم المستعار: $e'));
        _safeNotify();
        return;
      }
    }
    await _loadMyConversationsAndParticipants();
  }

  Future<void> setConversationArchived(
    String conversationId, {
    required bool archived,
  }) async {
    try {
      await _chat.setConversationArchived(
        conversationId: conversationId,
        archived: archived,
      );
    } catch (e) {
      _setError(_trChat('تعذر تحديث الأرشفة: $e'));
    }

    final parts = _participantsByConv[conversationId];
    if (parts != null) {
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].userUid == currentUid) {
          parts[i] = ChatParticipantLocal(
            conversationId: parts[i].conversationId,
            userUid: parts[i].userUid,
            email: parts[i].email,
            joinedAt: parts[i].joinedAt,
            nickname: parts[i].nickname,
            role: parts[i].role,
            archived: archived,
            pinned: parts[i].pinned,
            blocked: parts[i].blocked,
            isDeleted: parts[i].isDeleted,
          );
          break;
        }
      }
      _participantsByConv[conversationId] = parts;
      try {
        await _local.upsertParticipants(
          parts.map((p) => p.toMap()).toList(),
        );
      } catch (_) {}
    }

    // لا نحذفها من القائمة، لأن شاشة "المؤرشفة" تحتاجها للعرض.
    _safeNotify();
  }

  Future<void> deleteConversationForMe(String conversationId) async {
    try {
      await _chat.deleteConversationForMe(conversationId: conversationId);
    } catch (e) {
      _setError(_trChat('تعذر حذف المحادثة: $e'));
    }

    final parts = _participantsByConv[conversationId];
    if (parts != null) {
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].userUid == currentUid) {
          parts[i] = ChatParticipantLocal(
            conversationId: parts[i].conversationId,
            userUid: parts[i].userUid,
            email: parts[i].email,
            joinedAt: parts[i].joinedAt,
            nickname: parts[i].nickname,
            role: parts[i].role,
            archived: parts[i].archived,
            pinned: parts[i].pinned,
            blocked: parts[i].blocked,
            isDeleted: true,
          );
          break;
        }
      }
      _participantsByConv[conversationId] = parts;
      try {
        await _local.upsertParticipants(
          parts.map((p) => p.toMap()).toList(),
        );
      } catch (_) {}
    }

    _conversations.removeWhere((c) => c.id == conversationId);
    _safeNotify();
  }

  Future<void> acceptGroupInvitation(String invitationId) async {
    if (invitationId.isEmpty) return;
    try {
      await _chat.acceptGroupInvitation(invitationId);
      await refreshConversations();
    } on ChatInvitationException catch (e) {
      _rpcWarn('chat_accept_invitation failed', e);
      _setError(e.message);
      _safeNotify();
      rethrow;
    }
  }

  Future<void> declineGroupInvitation(
    String invitationId, {
    String? note,
  }) async {
    if (invitationId.isEmpty) return;
    try {
      await _chat.declineGroupInvitation(invitationId, note: note);
      await refreshInvitations();
    } on ChatInvitationException catch (e) {
      _rpcWarn('chat_decline_invitation failed', e);
      _setError(e.message);
      _safeNotify();
      rethrow;
    }
  }

  void _rpcWarn(String label, Object error, [StackTrace? st]) {
    log.w('Chat RPC warning: $label -> $error', tag: 'CHAT_RPC', st: st);
    _chatWarn(
      ObsCode.chatRpcWarning,
      'chat RPC warning',
      flowId: _newChatFlow('rpc_warning'),
      context: {
        'label': label,
      },
      error: error,
      stackTrace: st,
    );
  }

  Future<Map<String, dynamic>> _runQuery(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    if (!_isOnline) return <String, dynamic>{};
    final result = await _gql.query(
      QueryOptions(
        document: gql(doc),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (result.hasException) {
      throw result.exception!;
    }
    return result.data ?? <String, dynamic>{};
  }

  List<Map<String, dynamic>> _rowsFromData(
    Map<String, dynamic> data,
    String key,
  ) {
    final raw = data[key];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  // --------------------------------------------------------------------------
  // Handlers من RealtimeNotifier
  // --------------------------------------------------------------------------
  Map<String, dynamic> _newRec(dynamic payload) {
    try {
      final dyn = payload as dynamic;
      final obj = dyn.newRecord ?? dyn.record;
      if (obj is Map) {
        return Map<String, dynamic>.from(
          obj.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    } catch (_) {}
    try {
      if (payload is Map) {
        final m = payload;
        final obj = m['new'] ?? m['record'] ?? m['newRecord'];
        if (obj is Map) {
          return Map<String, dynamic>.from(
            obj.map((k, v) => MapEntry(k.toString(), v)),
          );
        }
      }
    } catch (_) {}
    return const {};
  }

  void _handleMessageInsert(dynamic payload) {
    final rec = _newRec(payload);
    final cid = (rec['conversation_id'] ?? '').toString();
    if (cid.isEmpty) return;

    final createdAtRaw = (rec['created_at'] ?? '').toString().trim();
    final createdAt = createdAtRaw.isNotEmpty
        ? DateTime.tryParse(createdAtRaw)?.toUtc()
        : null;
    final effectiveCreatedAt =
        createdAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final senderUid = (rec['sender_uid'] ?? '').toString();
    final kind = (rec['kind'] ?? '').toString().toLowerCase();
    final body = ((rec['body'] ?? rec['text']) ?? '').toString().trim();
    String snippet;
    if (kind == 'image') {
      snippet = _trChat('📷 صورة');
    } else if (kind == 'file') {
      snippet = _trChat('📎 ملف');
    } else if (kind == 'system') {
      snippet = _supportSnippetFromBody(body) ?? _trChat('رسالة نظام');
    } else if (body.isNotEmpty) {
      snippet = body;
    } else {
      snippet = _trChat('رسالة');
    }
    snippet = _trimSnippet(snippet);

    _fastBumpConversationOnNewMessage(
      cid: cid,
      createdAt: effectiveCreatedAt,
      snippet: snippet,
      fromUid: senderUid,
    );

    if (senderUid.isNotEmpty &&
        senderUid != currentUid &&
        _openedConversationId != cid) {
      final messageId = (rec['id'] ?? '').toString();
      if (messageId.isNotEmpty && createdAt != null) {
        unawaited(
          _maybeMarkDeliveredOnIncoming(
            conversationId: cid,
            messageId: messageId,
            createdAt: createdAt,
            senderUid: senderUid,
          ),
        );
      }
    }

    if (!(kind == 'system' && _isSupportRatingResponseBody(body))) {
      unawaited(_maybeSetPendingOnIncoming(cid, senderUid));
    } else {
      unawaited(
        _maybeSendSupportFollowupFromResponse(
          cid,
          body,
          senderUid,
          effectiveCreatedAt,
        ),
      );
    }
  }

  Future<void> _maybeMarkDeliveredOnIncoming({
    required String conversationId,
    required String messageId,
    required DateTime createdAt,
    required String senderUid,
  }) async {
    if (!_isOnline || _disposed) return;
    final uid = currentUid;
    if (uid.isEmpty || senderUid.isEmpty || senderUid == uid) return;
    if (conversationId.isEmpty ||
        messageId.isEmpty ||
        messageId.startsWith('local-')) {
      return;
    }

    final existingStates =
        _readStatesByConv[conversationId] ?? const <CM.ChatReadState>[];
    final existing = existingStates.firstWhere(
      (s) => s.userUid == uid,
      orElse: () => const CM.ChatReadState(conversationId: '', userUid: ''),
    );
    final prior = existing.userUid.isEmpty ? null : existing;
    final deliveredAt = prior?.lastDeliveredAt;
    if (deliveredAt != null && !deliveredAt.isBefore(createdAt)) {
      return;
    }

    try {
      await _chat.markDeliveredUpTo(
        conversationId: conversationId,
        messageId: messageId,
        createdAt: createdAt,
      );
    } catch (_) {
      return;
    }

    final states = List<CM.ChatReadState>.from(existingStates);
    final updated = CM.ChatReadState(
      conversationId: conversationId,
      userUid: uid,
      lastDeliveredAt: createdAt,
      lastDeliveredMessageId: messageId,
      lastReadAt: prior?.lastReadAt,
      lastReadMessageId: prior?.lastReadMessageId,
    );
    final idx = states.indexWhere((s) => s.userUid == uid);
    if (idx == -1) {
      states.add(updated);
    } else {
      states[idx] = updated;
    }
    _readStatesByConv[conversationId] = states;
    try {
      await _local.upsertReadStates([updated]);
    } catch (_) {}
    unawaited(_applyReadsToOutgoing(conversationId));
  }

  String? _supportSnippetFromBody(String body) {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final type = decoded['type']?.toString();
        if (type == 'support_rating_request') {
          return _trChat('استمارة تقييم خدمة العملاء');
        }
        if (type == 'support_rating_response') {
          return _trChat('تم تقييم خدمة العملاء');
        }
      }
    } catch (_) {}
    return null;
  }

  bool _isSupportRatingResponseBody(String body) {
    if (body.isEmpty) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        return decoded['type']?.toString() == 'support_rating_response';
      }
    } catch (_) {}
    return false;
  }

  Future<void> _maybeSendSupportFollowupFromResponse(
    String conversationId,
    String body,
    String senderUid,
    DateTime createdAt,
  ) async {
    if (!_isSupportAgent) return;
    if (!isSupportConversation(conversationId)) return;
    if (senderUid.isEmpty) return;
    if (senderUid == currentUid) return;
    if (createdAt.millisecondsSinceEpoch == 0) return;
    if (_bootAt.millisecondsSinceEpoch > 0 &&
        createdAt.isBefore(_bootAt.subtract(const Duration(seconds: 10)))) {
      return;
    }
    String sessionId = '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        sessionId = decoded['session_id']?.toString() ?? '';
      }
    } catch (_) {}
    if (sessionId.isEmpty) return;
    if (_supportFollowupSentSessions.contains(sessionId)) return;
    _supportFollowupSentSessions.add(sessionId);
    unawaited(_persistSupportFollowupSessions());
    try {
      await sendText(
        conversationId: conversationId,
        text: _trChat('لا تتردد في أي استفسار سنسعد بخدمتكم في أي وقت'),
      );
    } catch (_) {}
  }

  void _fastBumpConversationOnNewMessage({
    required String cid,
    required DateTime createdAt,
    required String snippet,
    required String fromUid,
  }) {
    final idx = _conversations.indexWhere((c) => c.id == cid);
    if (idx == -1) return;

    var c = _conversations[idx];
    final lastAt = c.lastMsgAt ?? c.createdAt;
    if (!createdAt.isAfter(lastAt)) {
      return;
    }
    var uc = c.unreadCount ?? 0;
    if (fromUid != currentUid) {
      final lr = _myLastReadByConv[cid];
      if (lr == null || createdAt.isAfter(lr)) {
        uc = (uc + 1).clamp(1, 9999);
      }
    }

    if (_openedConversationId == cid) {
      uc = 0;
      if (fromUid != currentUid) {
        unawaited(markConversationRead(cid));
      }
    }

    c = c.copyWith(
      lastMsgAt: createdAt,
      lastMsgSnippet: snippet,
      unreadCount: uc,
    );

    _conversations.removeAt(idx);
    _conversations.insert(0, c);
    _safeNotify();

    unawaited(_persistConversations([c]));
  }

  String _trimSnippet(String s) {
    final t = s.trim();
    return t.length > 80 ? '${t.substring(0, 80)}…' : t;
  }

  // --------------------------------------------------------------------------
  // فتح/إغلاق محادثة
  // --------------------------------------------------------------------------
  Future<void> _refreshReadStatesForConversation(String conversationId) async {
    if (conversationId.isEmpty) return;
    try {
      final query = '''
        query ReadStates(\$cid: uuid!) {
          $tableReads(where: {conversation_id: {_eq: \$cid}}) {
            conversation_id
            user_uid
            last_read_message_id
            last_read_at
            last_delivered_message_id
            last_delivered_at
          }
        }
      ''';
      final data = await _runQuery(query, {'cid': conversationId});
      final rows = _rowsFromData(data, tableReads);
      final states = rows.map(CM.ChatReadState.fromMap).toList();
      _readStatesByConv[conversationId] = states;
      await _local.upsertReadStates(states);
      _applyReadsToOutgoing(conversationId);
      if (_isOnline) {
        unawaited(_scheduleAttachmentCleanupForConversation(conversationId));
      }
    } catch (_) {}
  }

  Future<void> openConversation(String conversationId) async {
    if (conversationId.isEmpty || _disposed) return;

    if (_openedConversationId == conversationId && _roomMsgsSub != null) {
      if (_isOnline) {
        await markConversationRead(conversationId);
        await _applyReadsToOutgoing(conversationId);
      }
      return;
    }

    _openedConversationId = conversationId;
    unawaited(_rt.setActiveConversation(conversationId));

    final cached = await _local.getMessages(
      conversationId,
      accountId: _accountFilter,
      limit: 500,
    );
    if (_disposed) return;
    _messagesByConv[conversationId] = cached;
    _olderCursorByConv[conversationId] =
        cached.isNotEmpty ? cached.last.createdAt : null;
    _safeNotify();

    if (_isOnline) {
      await _refreshReadStatesForConversation(conversationId);
    }

    // ✅ حمّل دفعة حديثة للمحادثات الدائمة (الدعم)
    if (_isOnline && _allowRemoteHistory(conversationId)) {
      if (cached.isEmpty) {
        await loadMoreMessages(conversationId);
      } else {
        unawaited(_refreshLatestMessages(conversationId));
      }
    }

    // ✅ للمحادثات العادية: إذا كانت فارغة محليًا، اسحب أحدث الرسائل مرة واحدة
    if (_isOnline && !_allowRemoteHistory(conversationId)) {
      await _seedRecentMessagesIfNeeded(conversationId);
    }
    if (_disposed) return;

    // ✅ Prefetch للرسائل الظاهرة (صور فقط غالبًا)
    unawaited(prefetchVisibleAttachments(conversationId, maxMessages: 30));

    try {
      await _roomMsgsSub?.cancel();
    } catch (_) {}
    if (_isOnline) {
      final refreshed = _messagesByConv[conversationId] ?? const [];
      final since = refreshed.isNotEmpty
          ? refreshed.first.createdAt
          : DateTime.now().toUtc().subtract(const Duration(seconds: 5));
      _roomMsgsSub = _chat
          .watchMessages(
        conversationId,
        since: _allowRemoteHistory(conversationId) ? null : since,
        seedFromServer: _allowRemoteHistory(conversationId),
      )
          .listen(
        (remoteList) async {
          if (_disposed) return;
          final latest = _bindMessagesToActiveAccount(remoteList);
          await _persistMessages(latest);
          if (_disposed) return;
          _mergeIncomingMessages(conversationId, latest);

          _scheduleConversationsRefresh();
          _safeNotify();

          // ✅ Prefetch بعد كل دفعة واردة
          unawaited(
            prefetchVisibleAttachments(conversationId, maxMessages: 30),
          );

          await _applyReadsToOutgoing(conversationId);
        },
        onError: (e) {
          if (_disposed) return;
          // تجاهل أخطاء Realtime عند انقطاع الشبكة
          if (!_isOnline) return;
          _setError('Realtime error: $e');
          _safeNotify();
        },
      );
    }

    try {
      await _typingSub?.cancel();
    } catch (_) {}
    if (_isOnline) {
      _typingSub = _chat.typingStream(conversationId).listen((payload) {
        if (_disposed) return;
        final String convId = (payload['conversation_id'] ?? '').toString();
        if (convId.isEmpty || convId != conversationId) return;
        final active = (payload['active_uids'] as List?) ?? const [];
        final set = <String>{};
        for (final raw in active) {
          final uid = raw?.toString();
          if (uid != null && uid.isNotEmpty && uid != currentUid) {
            set.add(uid);
          }
        }
        _typingUidsByConv[convId] = set;
        _safeNotify();
      });
    }

    try {
      await _readsSub?.cancel();
    } catch (_) {}
    final readsSubDoc = '''
      subscription Reads(\$cid: uuid!) {
        $tableReads(where: {conversation_id: {_eq: \$cid}}) {
          conversation_id
          user_uid
          last_read_message_id
          last_read_at
          last_delivered_message_id
          last_delivered_at
        }
      }
    ''';
    if (_isOnline) {
      _readsSub = _gql
          .subscribe(
            SubscriptionOptions(
              document: gql(readsSubDoc),
              variables: {'cid': conversationId},
              fetchPolicy: FetchPolicy.noCache,
            ),
          )
          .listen((_) => _refreshReadStatesForConversation(conversationId));
    }

    if (_isOnline) {
      await markConversationRead(conversationId);
      await _applyReadsToOutgoing(conversationId);
    }
  }

  Future<void> closeConversation() async {
    _openedConversationId = null;
    unawaited(_rt.setActiveConversation(null));
    try {
      await _roomMsgsSub?.cancel();
      _roomMsgsSub = null;
    } catch (_) {}
    try {
      await _typingSub?.cancel();
      _typingSub = null;
    } catch (_) {}
    try {
      await _readsSub?.cancel();
    } catch (_) {}
    _readsSub = null;

    try {
      _listDebounce?.cancel();
    } catch (_) {}
    _typingPingDebounce?.cancel();
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
  }

  // --------------------------------------------------------------------------
  // جلب دفعات رسائل
  // --------------------------------------------------------------------------
  Future<List<CM.ChatMessage>> _fetchRecentBatchFromBackend({
    required String conversationId,
    int limit = 40,
    DateTime? before,
  }) async {
    if (before != null) {
      final list = await _chat.fetchOlderMessages(
        conversationId: conversationId,
        beforeCreatedAt: before,
        limit: limit,
      );
      return List<CM.ChatMessage>.from(list.reversed);
    }
    final list = await _chat.fetchMessages(
      conversationId: conversationId,
      limit: limit,
    );
    return List<CM.ChatMessage>.from(list.reversed);
  }

  // --------------------------------------------------------------------------
  // تحميل المزيد
  // --------------------------------------------------------------------------
  Future<void> loadMoreMessages(String conversationId) async {
    if (!_allowRemoteHistory(conversationId)) {
      final DateTime? before = _olderCursorByConv[conversationId];
      List<CM.ChatMessage> cached;
      if (before != null) {
        cached = await _local.getMessages(
          conversationId,
          accountId: _accountFilter,
          beforeIso: before.toUtc().toIso8601String(),
          limit: 40,
        );
      } else {
        cached = await _local.getMessages(
          conversationId,
          accountId: _accountFilter,
          limit: 40,
        );
      }
      if (cached.isNotEmpty) {
        final existing = List<CM.ChatMessage>.from(
          _messagesByConv[conversationId] ?? const [],
        );
        final existingIds = existing.map((m) => m.id).toSet();
        for (final m in cached) {
          if (!existingIds.contains(m.id)) existing.add(m);
        }
        _messagesByConv[conversationId] = existing;
        _olderCursorByConv[conversationId] = cached.last.createdAt;
        _safeNotify();
        await _applyReadsToOutgoing(conversationId);
      }
      return;
    }
    try {
      final DateTime? before = _olderCursorByConv[conversationId];

      final listDesc = await _fetchRecentBatchFromBackend(
        conversationId: conversationId,
        limit: 40,
        before: before,
      );

      final incoming = _bindMessagesToActiveAccount(listDesc);

      await _persistMessages(incoming);

      final existing = List<CM.ChatMessage>.from(
        _messagesByConv[conversationId] ?? const [],
      );
      final existingIds = existing.map((m) => m.id).toSet();
      for (final m in incoming) {
        if (!existingIds.contains(m.id)) {
          existing.add(m);
        }
      }
      _messagesByConv[conversationId] = existing;

      if (existing.isNotEmpty) {
        _olderCursorByConv[conversationId] = existing.last.createdAt;
      }

      _safeNotify();

      await _applyReadsToOutgoing(conversationId);
    } catch (e) {
      final DateTime? before = _olderCursorByConv[conversationId];

      List<CM.ChatMessage> cached;
      if (before != null) {
        cached = await _local.getMessages(
          conversationId,
          accountId: _accountFilter,
          beforeIso: before.toUtc().toIso8601String(),
          limit: 40,
        );
      } else {
        cached = await _local.getMessages(
          conversationId,
          accountId: _accountFilter,
          limit: 40,
        );
      }

      if (cached.isNotEmpty) {
        final existing = List<CM.ChatMessage>.from(
          _messagesByConv[conversationId] ?? const [],
        );
        final existingIds = existing.map((m) => m.id).toSet();
        for (final m in cached) {
          if (!existingIds.contains(m.id)) existing.add(m);
        }
        _messagesByConv[conversationId] = existing;
        _olderCursorByConv[conversationId] = cached.last.createdAt;
        _safeNotify();

        await _applyReadsToOutgoing(conversationId);
      } else {
        _setError(_trChat('تعذّر تحميل الرسائل: $e'));
        _safeNotify();
      }
    }
  }

  Future<void> _refreshLatestMessages(String conversationId) async {
    if (!_allowRemoteHistory(conversationId)) return;
    try {
      final listDesc = await _fetchRecentBatchFromBackend(
        conversationId: conversationId,
        limit: 40,
      );
      final incoming = _bindMessagesToActiveAccount(listDesc);
      await _persistMessages(incoming);
      _mergeIncomingMessages(conversationId, incoming);
      _safeNotify();
    } catch (_) {}
  }

  Future<void> _seedRecentMessagesIfNeeded(String conversationId) async {
    if (!_isOnline || _allowRemoteHistory(conversationId)) return;
    final existing = _messagesByConv[conversationId] ?? const [];
    if (existing.isNotEmpty) return;
    try {
      final listDesc = await _fetchRecentBatchFromBackend(
        conversationId: conversationId,
        limit: 40,
      );
      if (listDesc.isEmpty) return;
      final incoming = _bindMessagesToActiveAccount(listDesc);
      await _persistMessages(incoming);
      _mergeIncomingMessages(conversationId, incoming);
      _safeNotify();
    } catch (_) {
      // تجاهل الخطأ لتفادي كسر فتح المحادثة
    }
  }

  void _mergeIncomingMessages(
    String conversationId,
    List<CM.ChatMessage> incoming,
  ) {
    incoming = _bindMessagesToActiveAccount(incoming);
    final existing =
        List<CM.ChatMessage>.from(_messagesByConv[conversationId] ?? const []);
    final map = <String, CM.ChatMessage>{};
    final existingIds = <String>{};
    for (final m in existing) {
      if (m.id.isNotEmpty) {
        map[m.id] = m;
        existingIds.add(m.id);
      }
    }
    for (final m in incoming) {
      if (m.id.isNotEmpty) {
        final prev = map[m.id];
        if (prev != null &&
            m.attachments.isEmpty &&
            prev.attachments.isNotEmpty) {
          map[m.id] = prev.copyWith(attachments: prev.attachments);
        } else {
          map[m.id] = m;
        }
        if (!existingIds.contains(m.id) && m.senderUid != currentUid) {
          _recentIncomingMessageIds[m.id] = DateTime.now().toUtc();
        }
      }
    }
    _pruneRecentIncoming();
    final merged = map.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (merged.length > 500) {
      merged.removeRange(500, merged.length);
    }
    _messagesByConv[conversationId] = merged;
    _olderCursorByConv[conversationId] =
        merged.isNotEmpty ? merged.last.createdAt : null;
  }

  // --------------------------------------------------------------------------
  // إرسال نص/صور
  // --------------------------------------------------------------------------
  void _requestOutboxFlush({
    required String reason,
    Duration delay = Duration.zero,
  }) {
    if (_disposed || !_isOnline || !hasBoundChatAccount(_accountFilter)) {
      return;
    }
    _outboxFlushRequested = true;
    final activeTimer = _outboxRetryTimer;
    if (activeTimer != null && activeTimer.isActive) {
      if (delay > Duration.zero) {
        return;
      }
      activeTimer.cancel();
    }
    _outboxRetryTimer = Timer(delay, () {
      _outboxRetryTimer = null;
      if (_disposed || !_isOnline || !hasBoundChatAccount(_accountFilter)) {
        return;
      }
      unawaited(_flushOutbox());
    });
  }

  void _scheduleOutboxRetry(
    String reason,
    Object error,
    StackTrace stackTrace, {
    String? localId,
    String? conversationId,
    String? kind,
  }) {
    _outboxRetryAttempt += 1;
    final delay = _kOutboxRetryPolicy.delayForAttempt(_outboxRetryAttempt);
    _chatWarn(
      ObsCode.chatOutboxFlushFailed,
      'chat outbox flush failed; scheduling retry',
      flowId: _newChatFlow('outbox_retry'),
      context: {
        'reason': reason,
        'retryAttempt': _outboxRetryAttempt,
        'retryDelayMs': delay.inMilliseconds,
        'localId': localId,
        'conversationId': conversationId,
        'kind': kind,
      },
      error: error,
      stackTrace: stackTrace,
    );
    _requestOutboxFlush(reason: reason, delay: delay);
  }

  Future<void> _enqueueOutbox({
    required String localId,
    required String conversationId,
    required String kind,
    required String body,
    List<String>? attachmentPaths,
    String? replyToMessageId,
    String? replyToSnippet,
    List<String>? mentions,
  }) async {
    final accountId = _requiredChatAccountId();
    final storedAttachmentPaths = attachmentPaths == null
        ? null
        : await _stageOutboxAttachments(localId, attachmentPaths);
    final payload = <String, dynamic>{
      'local_id': localId,
      'conversation_id': conversationId,
      'account_id': accountId,
      'kind': kind,
      'body': body,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'reply_to_message_id': replyToMessageId,
      'reply_to_snippet': replyToSnippet,
      'mentions_json': mentions == null ? null : jsonEncode(mentions),
      'attachments_json':
          storedAttachmentPaths == null ? null : jsonEncode(storedAttachmentPaths),
      'status': 'queued',
      'error': null,
    };
    await _local.upsertOutboxMessage(payload);
    _requestOutboxFlush(reason: 'enqueue_outbox');
  }

  Future<List<String>> _stageOutboxAttachments(
    String localId,
    List<String> attachmentPaths,
  ) async {
    final stageRoot = Directory(
      p.join(Directory.systemTemp.path, _outboxStageDirName),
    );
    await stageRoot.create(recursive: true);
    final stageRootPath = p.normalize(stageRoot.path);
    final stored = <String>[];
    for (var i = 0; i < attachmentPaths.length; i++) {
      final rawPath = attachmentPaths[i].trim();
      if (rawPath.isEmpty) continue;
      final source = File(rawPath);
      if (!await source.exists()) continue;
      final normalizedSource = p.normalize(source.path);
      if (p.isWithin(stageRootPath, normalizedSource)) {
        stored.add(source.path);
        continue;
      }
      final baseName = p
          .basenameWithoutExtension(source.path)
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final extension = p.extension(source.path);
      final fileName =
          '${DateTime.now().microsecondsSinceEpoch}_${localId}_${i}_${baseName.isEmpty ? 'attachment' : baseName}$extension';
      final target = File(p.join(stageRootPath, fileName));
      try {
        await source.copy(target.path);
        stored.add(target.path);
      } catch (_) {
        stored.add(source.path);
      }
    }
    return stored;
  }

  List<String> _outboxAttachmentPathsFromItem(Map<String, dynamic> item) {
    final raw = item['attachments_json']?.toString();
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((entry) => entry.toString())
          .where((entry) => entry.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _cleanupOutboxAttachments(Iterable<String> paths) async {
    final stageRoot = p.normalize(
      p.join(Directory.systemTemp.path, _outboxStageDirName),
    );
    for (final rawPath in paths) {
      final normalized = p.normalize(rawPath);
      if (!p.isWithin(stageRoot, normalized)) continue;
      try {
        final file = File(rawPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  Future<void> _markOutboxItemFailed({
    required String localId,
    required String conversationId,
    required String message,
    Iterable<String> attachmentPaths = const <String>[],
  }) async {
    final list = List<CM.ChatMessage>.from(
      _messagesByConv[conversationId] ?? const [],
    );
    final idx = list.indexWhere((m) => m.id == localId);
    if (idx != -1) {
      list[idx] = list[idx].copyWith(status: CM.ChatMessageStatus.failed);
      _messagesByConv[conversationId] = list;
      _safeNotify();
    }
    try {
      await _local.updateMessageStatus(
        messageId: localId,
        status: CM.ChatMessageStatus.failed,
      );
    } catch (_) {}
    try {
      await _local.updateOutboxMessageState(
        localId: localId,
        status: 'failed',
        error: message,
      );
    } catch (_) {}
    await _local.deleteOutboxMessage(localId);
    await _cleanupOutboxAttachments(attachmentPaths);
    _chatWarn(
      ObsCode.chatOutboxFlushFailed,
      'chat outbox item failed permanently',
      flowId: _newChatFlow('outbox_drop'),
      context: {
        'localId': localId,
        'conversationId': conversationId,
        'reason': message,
      },
    );
    _setError(message);
    _safeNotify();
  }

  Future<bool> _flushOutboxItem(Map<String, dynamic> item) async {
    final localId = item['local_id']?.toString() ?? '';
    final cid = item['conversation_id']?.toString() ?? '';
    final kind = (item['kind']?.toString() ?? 'text').toLowerCase();
    final body = item['body']?.toString() ?? '';
    final attachmentPaths = _outboxAttachmentPathsFromItem(item);
    final itemAccountId = item['account_id']?.toString().trim();
    final activeAccountId = _requiredChatAccountId();
    if (localId.isEmpty || cid.isEmpty) {
      await _cleanupOutboxAttachments(attachmentPaths);
      await _local.deleteOutboxMessage(localId);
      return true;
    }
    if (itemAccountId != null &&
        itemAccountId.isNotEmpty &&
        itemAccountId != activeAccountId) {
      await _cleanupOutboxAttachments(attachmentPaths);
      await _local.deleteOutboxMessage(localId);
      return true;
    }

    if (kind == 'att_downloaded' || kind == 'att_opened') {
      final dev = await _ensureDeviceId();
      if (dev == null || dev.trim().isEmpty) {
        throw StateError('chat device id is unavailable for outbox flush');
      }
      if (body.trim().isEmpty) {
        await _local.deleteOutboxMessage(localId);
        return true;
      }
      if (kind == 'att_downloaded') {
        await _chat.markAttachmentDownloaded(
          attachmentId: body.trim(),
          deviceId: dev,
        );
      } else {
        await _chat.markAttachmentOpened(
          attachmentId: body.trim(),
          deviceId: dev,
        );
      }
      await _local.deleteOutboxMessage(localId);
      return true;
    }

    if (kind == 'image' || kind == 'file') {
      if (!AppConstants.chatAllowAttachments) {
        await _cleanupOutboxAttachments(attachmentPaths);
        await _local.deleteOutboxMessage(localId);
        return true;
      }
      final files = attachmentPaths
          .map((path) => File(path))
          .where((file) => file.existsSync())
          .toList();
      if (attachmentPaths.isEmpty || files.length != attachmentPaths.length) {
        await _markOutboxItemFailed(
          localId: localId,
          conversationId: cid,
          message: _trChat(
            'تعذر استكمال إرسال المرفقات لأن الملف المحلي لم يعد متاحًا.',
          ),
          attachmentPaths: attachmentPaths,
        );
        return true;
      }
      final sent = kind == 'file'
          ? await _chat.sendFiles(
              conversationId: cid,
              files: files,
              optionalText: body.isEmpty ? null : body,
              localSeq: _generateLocalSeq(),
              clientMsgId: localId,
            )
          : await _chat.sendImages(
              conversationId: cid,
              files: files,
              optionalText: body.isEmpty ? null : body,
              localSeq: _generateLocalSeq(),
              clientMsgId: localId,
              combineTextWithImages: true,
            );
      if (sent.isEmpty) {
        throw StateError('chat attachment outbox flush returned no messages');
      }
      final boundSent = _bindMessagesToActiveAccount(sent);
      await _cleanupOutboxAttachments(attachmentPaths);
      await _local.deleteOutboxMessage(localId);
      final list = List<CM.ChatMessage>.from(_messagesByConv[cid] ?? const []);
      list.removeWhere((m) => m.id == localId);
      for (final m in boundSent.reversed) {
        list.insert(0, m.copyWith(status: CM.ChatMessageStatus.sent));
      }
      _messagesByConv[cid] = list;
      _safeNotify();
      await _persistMessages(boundSent);
      return true;
    }

    if (kind == 'system') {
      final real = _bindMessageToActiveAccount(
        await _chat.sendSystemMessage(
          conversationId: cid,
          body: body,
          localSeq: _generateLocalSeq(),
          clientMsgId: localId,
        ),
      );
      await _local.deleteOutboxMessage(localId);
      final list = List<CM.ChatMessage>.from(_messagesByConv[cid] ?? const []);
      final idx = list.indexWhere((m) => m.id == localId);
      if (idx != -1) {
        list[idx] = real.copyWith(status: CM.ChatMessageStatus.sent);
      } else {
        list.insert(0, real.copyWith(status: CM.ChatMessageStatus.sent));
      }
      _messagesByConv[cid] = list;
      _safeNotify();
      await _persistMessages([real]);
      return true;
    }

    final real = _bindMessageToActiveAccount(
      await _chat.sendText(
        conversationId: cid,
        body: body,
        localSeq: _generateLocalSeq(),
        clientMsgId: localId,
      ),
    );
    await _local.deleteOutboxMessage(localId);
    final list = List<CM.ChatMessage>.from(_messagesByConv[cid] ?? const []);
    final idx = list.indexWhere((m) => m.id == localId);
    if (idx != -1) {
      list[idx] = real.copyWith(status: CM.ChatMessageStatus.sent);
    } else {
      list.insert(0, real.copyWith(status: CM.ChatMessageStatus.sent));
    }
    _messagesByConv[cid] = list;
    _safeNotify();
    await _persistMessages([real]);
    return true;
  }

  Future<void> _flushOutbox() async {
    if (_disposed || !_isOnline || !hasBoundChatAccount(_accountFilter)) {
      return;
    }
    if (_outboxFlushInProgress) {
      _outboxFlushRequested = true;
      return;
    }
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _outboxFlushInProgress = true;
    try {
      final accountId = _requiredChatAccountId();
      var continueDraining = true;
      while (continueDraining &&
          !_disposed &&
          _isOnline &&
          hasBoundChatAccount(_accountFilter)) {
        _outboxFlushRequested = false;
        final items = await _local.getOutbox(accountId: accountId);
        if (items.isEmpty) {
          _outboxRetryAttempt = 0;
          break;
        }

        continueDraining = false;
        var retryScheduled = false;
        for (final item in items) {
          final localId = item['local_id']?.toString();
          final cid = item['conversation_id']?.toString();
          final kind = item['kind']?.toString();
          try {
            final completed = await _flushOutboxItem(item);
            if (!completed) {
              continueDraining = false;
              break;
            }
          } catch (e, st) {
            _scheduleOutboxRetry(
              'flush_item_failed',
              e,
              st,
              localId: localId,
              conversationId: cid,
              kind: kind,
            );
            retryScheduled = true;
            continueDraining = false;
            break;
          }
          if (_disposed || !_isOnline || !hasBoundChatAccount(_accountFilter)) {
            return;
          }
          continueDraining = _outboxFlushRequested;
        }
        if (!continueDraining && !retryScheduled && items.length >= 200) {
          continueDraining = true;
        }
      }
    } finally {
      _outboxFlushInProgress = false;
      if (_outboxFlushRequested &&
          !_disposed &&
          _isOnline &&
          hasBoundChatAccount(_accountFilter)) {
        _requestOutboxFlush(reason: 'followup_flush');
      }
    }
  }

  Future<void> sendSystemMessage({
    required String conversationId,
    required Map<String, dynamic> payload,
    String? snippetLabel,
  }) async {
    if (_disposed) return;
    final body = jsonEncode(payload);
    final now = DateTime.now().toUtc();
    final optimistic = CM.ChatMessage(
      id: 'local-${now.microsecondsSinceEpoch}',
      conversationId: conversationId,
      senderUid: currentUid,
      senderEmail: myEmail,
      kind: CM.ChatMessageKind.system,
      body: body,
      createdAt: now,
      status: CM.ChatMessageStatus.sending,
      accountId: _accountFilter,
    );

    final list = List<CM.ChatMessage>.from(
      _messagesByConv[conversationId] ?? const [],
    );
    list.insert(0, optimistic);
    _messagesByConv[conversationId] = list;
    _safeNotify();

    _applyOutgoingToConversationList(
      conversationId,
      snippetLabel ?? _trChat('رسالة نظام'),
    );
    unawaited(_maybeAdvanceToUnderReview(conversationId));

    await _persistMessages([optimistic]);

    if (!_isOnline) {
      try {
        await _enqueueOutbox(
          localId: optimistic.id,
          conversationId: conversationId,
          kind: 'system',
          body: body,
        );
      } catch (_) {}
      return;
    }

    try {
      final real = _bindMessageToActiveAccount(await _chat.sendSystemMessage(
        conversationId: conversationId,
        body: body,
        localSeq: _generateLocalSeq(),
        clientMsgId: optimistic.id,
      ));
      final replaced = List<CM.ChatMessage>.from(
        _messagesByConv[conversationId] ?? const [],
      );
      final idx = replaced.indexWhere((m) => m.id == optimistic.id);
      if (idx != -1) {
        replaced[idx] = real.copyWith(status: CM.ChatMessageStatus.sent);
      } else {
        replaced.insert(0, real.copyWith(status: CM.ChatMessageStatus.sent));
      }
      _messagesByConv[conversationId] = replaced;
      _safeNotify();
      await _local.deleteMessage(optimistic.id);
      await _persistMessages([real]);
      _scheduleConversationsRefresh();
    } catch (_) {
      final replaced = List<CM.ChatMessage>.from(
        _messagesByConv[conversationId] ?? const [],
      );
      final idx = replaced.indexWhere((m) => m.id == optimistic.id);
      if (idx != -1) {
        replaced[idx] = replaced[idx].copyWith(
          status: CM.ChatMessageStatus.failed,
        );
        _messagesByConv[conversationId] = replaced;
        _safeNotify();
      }
      await _local.updateMessageStatus(
        messageId: optimistic.id,
        status: CM.ChatMessageStatus.failed,
      );
    }
  }

  Future<void> sendText({
    required String conversationId,
    required String text,
  }) async {
    final body = text.trim();
    if (body.isEmpty || _disposed) return;

    final optimistic = CM.ChatMessage.optimisticText(
      conversationId: conversationId,
      senderUid: currentUid,
      senderEmail: myEmail,
      text: body,
      accountId: _accountFilter,
    );

    final list = List<CM.ChatMessage>.from(
      _messagesByConv[conversationId] ?? const [],
    );
    list.insert(0, optimistic);
    _messagesByConv[conversationId] = list;
    _safeNotify();

    _applyOutgoingToConversationList(conversationId, body);
    unawaited(_maybeAdvanceToUnderReview(conversationId));

    await _persistMessages([optimistic]);

    if (!_isOnline) {
      try {
        await _enqueueOutbox(
          localId: optimistic.id,
          conversationId: conversationId,
          kind: 'text',
          body: body,
          replyToMessageId: optimistic.replyToMessageId,
          replyToSnippet: optimistic.replyToSnippet,
          mentions: optimistic.mentions,
        );
      } catch (_) {}
      return;
    }

    try {
      final real = _bindMessageToActiveAccount(await _chat.sendText(
        conversationId: conversationId,
        body: body,
        localSeq: _generateLocalSeq(),
        clientMsgId: optimistic.localId,
      ));

      final replaced = List<CM.ChatMessage>.from(
        _messagesByConv[conversationId] ?? const [],
      );
      final idx = replaced.indexWhere((m) => m.id == optimistic.id);
      if (idx != -1) {
        replaced[idx] = real.copyWith(status: CM.ChatMessageStatus.sent);
      } else {
        if (!replaced.any((m) => m.id == real.id)) {
          replaced.insert(0, real.copyWith(status: CM.ChatMessageStatus.sent));
          replaced.removeWhere((m) => m.id == optimistic.id);
        }
      }
      _messagesByConv[conversationId] = replaced;
      _safeNotify();

      await _local.deleteMessage(optimistic.id);
      await _persistMessages([
        replaced.firstWhere((m) => m.id == real.id, orElse: () => real),
      ]);

      _scheduleConversationsRefresh();
      await _applyReadsToOutgoing(conversationId);
    } catch (e) {
      final replaced = List<CM.ChatMessage>.from(
        _messagesByConv[conversationId] ?? const [],
      );
      final idx = replaced.indexWhere((m) => m.id == optimistic.id);
      if (idx != -1) {
        replaced[idx] = replaced[idx].copyWith(
          status: CM.ChatMessageStatus.failed,
        );
        _messagesByConv[conversationId] = replaced;
        _safeNotify();
      }
      await _local.updateMessageStatus(
        messageId: optimistic.id,
        status: CM.ChatMessageStatus.failed,
      );
      try {
        await _enqueueOutbox(
          localId: optimistic.id,
          conversationId: conversationId,
          kind: 'text',
          body: body,
          replyToMessageId: optimistic.replyToMessageId,
          replyToSnippet: optimistic.replyToSnippet,
          mentions: optimistic.mentions,
        );
      } catch (_) {}
      _setError(_trChat('تعذّر إرسال الرسالة: $e'));
      _safeNotify();
    }
  }

  void _applyOutgoingToConversationList(
    String conversationId,
    String bodyOrLabel,
  ) {
    final idx = _conversations.indexWhere((c) => c.id == conversationId);
    if (idx == -1) return;
    var c = _conversations[idx];
    c = c.copyWith(
      lastMsgAt: DateTime.now().toUtc(),
      lastMsgSnippet: _trimSnippet(bodyOrLabel),
    );
    _conversations.removeAt(idx);
    _conversations.insert(0, c);
    _safeNotify();
    unawaited(_persistConversations([c]));
  }

  Future<void> sendImages({
    required String conversationId,
    required List<File> files,
    String? optionalText,
  }) async {
    if (_disposed) return;
    if (!AppConstants.chatAllowAttachments) {
      throw _trChat('تم إيقاف إرسال المرفقات في هذا الإصدار.');
    }
    if (files.isEmpty &&
        (optionalText == null || optionalText.trim().isEmpty)) {
      return;
    }

    _applyOutgoingToConversationList(conversationId, _trChat('📷 صورة'));
    unawaited(_maybeAdvanceToUnderReview(conversationId));

    final prepared = await _chat.prepareImageFiles(files);
    final optimistic = CM.ChatMessage.optimisticImages(
      conversationId: conversationId,
      senderUid: currentUid,
      senderEmail: myEmail,
      files: prepared,
      caption: optionalText,
      accountId: _accountFilter,
    );
    final list = List<CM.ChatMessage>.from(
      _messagesByConv[conversationId] ?? const [],
    );
    list.insert(0, optimistic);
    _messagesByConv[conversationId] = list;
    _safeNotify();
    await _persistMessages([optimistic]);

    if (!_isOnline) {
      try {
        await _enqueueOutbox(
          localId: optimistic.id,
          conversationId: conversationId,
          kind: 'image',
          body: (optionalText ?? '').trim(),
          attachmentPaths: prepared.map((f) => f.path).toList(),
        );
      } catch (_) {}
      return;
    }

    try {
      final sent = _bindMessagesToActiveAccount(await _chat.sendImages(
        conversationId: conversationId,
        files: prepared,
        optionalText: optionalText,
        localSeq: _generateLocalSeq(),
        clientMsgId: optimistic.localId,
        combineTextWithImages: true,
      ));

      if (sent.isNotEmpty) {
        final list = List<CM.ChatMessage>.from(
          _messagesByConv[conversationId] ?? const [],
        );
        final existingIds = list.map((m) => m.id).toSet();

        list.removeWhere((m) => m.id == optimistic.id);

        for (var m in sent.reversed) {
          if (m.senderUid == currentUid &&
              m.status != CM.ChatMessageStatus.read) {
            m = m.copyWith(status: CM.ChatMessageStatus.sent);
          }
          if (!existingIds.contains(m.id)) list.insert(0, m);
        }
        _messagesByConv[conversationId] = list;
        _safeNotify();

        await _persistMessages(sent);
        await _local.deleteMessage(optimistic.id);
        unawaited(_seedLocalAttachmentsFromSent(sent, prepared));
      }

      _scheduleConversationsRefresh();
      await _applyReadsToOutgoing(conversationId);
    } on ChatAttachmentUploadException catch (e) {
      _setError(e.message);
      _safeNotify();
      try {
        await _local.updateMessageStatus(
          messageId: optimistic.id,
          status: CM.ChatMessageStatus.failed,
        );
      } catch (_) {}
      rethrow;
    } catch (e) {
      final failedList = List<CM.ChatMessage>.from(
        _messagesByConv[conversationId] ?? const [],
      );
      final idx = failedList.indexWhere((m) => m.id == optimistic.id);
      if (idx != -1) {
        failedList[idx] =
            failedList[idx].copyWith(status: CM.ChatMessageStatus.failed);
        _messagesByConv[conversationId] = failedList;
        _safeNotify();
      }
      try {
        await _local.updateMessageStatus(
          messageId: optimistic.id,
          status: CM.ChatMessageStatus.failed,
        );
      } catch (_) {}
      try {
        await _enqueueOutbox(
          localId: optimistic.id,
          conversationId: conversationId,
          kind: 'image',
          body: (optionalText ?? '').trim(),
          attachmentPaths: prepared.map((f) => f.path).toList(),
        );
      } catch (_) {}
      _setError(_trChat('تعذّر إرسال الصور: $e'));
      _safeNotify();
      rethrow;
    }
  }

  Future<void> sendFiles({
    required String conversationId,
    required List<File> files,
    String? optionalText,
  }) async {
    if (_disposed) return;
    if (!AppConstants.chatAllowAttachments) {
      throw _trChat('تم إيقاف إرسال المرفقات في هذا الإصدار.');
    }
    if (files.isEmpty &&
        (optionalText == null || optionalText.trim().isEmpty)) {
      return;
    }

    _applyOutgoingToConversationList(conversationId, _trChat('📎 ملف'));
    unawaited(_maybeAdvanceToUnderReview(conversationId));

    final optimistic = CM.ChatMessage.optimisticFiles(
      conversationId: conversationId,
      senderUid: currentUid,
      senderEmail: myEmail,
      files: files,
      caption: optionalText,
      accountId: _accountFilter,
    );
    final list = List<CM.ChatMessage>.from(
      _messagesByConv[conversationId] ?? const [],
    );
    list.insert(0, optimistic);
    _messagesByConv[conversationId] = list;
    _safeNotify();
    await _persistMessages([optimistic]);

    if (!_isOnline) {
      try {
        await _enqueueOutbox(
          localId: optimistic.id,
          conversationId: conversationId,
          kind: 'file',
          body: (optionalText ?? '').trim(),
          attachmentPaths: files.map((f) => f.path).toList(),
        );
      } catch (_) {}
      return;
    }

    try {
      final sent = _bindMessagesToActiveAccount(await _chat.sendFiles(
        conversationId: conversationId,
        files: files,
        optionalText: (optionalText ?? '').trim(),
      ));
      final latest = List<CM.ChatMessage>.from(sent);
      await _persistMessages(latest);
      _mergeIncomingMessages(conversationId, latest);
      _scheduleConversationsRefresh();
      _safeNotify();
      unawaited(_seedLocalAttachmentsFromSent(latest, files));
    } catch (e) {
      final failedList = List<CM.ChatMessage>.from(
        _messagesByConv[conversationId] ?? const [],
      );
      final idx = failedList.indexWhere((m) => m.id == optimistic.id);
      if (idx != -1) {
        failedList[idx] =
            failedList[idx].copyWith(status: CM.ChatMessageStatus.failed);
        _messagesByConv[conversationId] = failedList;
        _safeNotify();
      }
      try {
        await _local.updateMessageStatus(
          messageId: optimistic.id,
          status: CM.ChatMessageStatus.failed,
        );
      } catch (_) {}
      try {
        await _enqueueOutbox(
          localId: optimistic.id,
          conversationId: conversationId,
          kind: 'file',
          body: (optionalText ?? '').trim(),
          attachmentPaths: files.map((f) => f.path).toList(),
        );
      } catch (_) {}
      _setError(_trChat('تعذّر إرسال الملفات: $e'));
      _safeNotify();
      rethrow;
    }
  }

  // --------------------------------------------------------------------------
  // صلاحيات تعديل/حذف
  // --------------------------------------------------------------------------
  bool canEditMessageNow(CM.ChatMessage m) {
    if (m.deleted) return false;
    if (m.senderUid != currentUid) return false;
    if (m.kind != CM.ChatMessageKind.text) return false;
    final dt = m.createdAt;
    final diff = DateTime.now().toUtc().difference(dt);
    return diff <= editWindow;
  }

  bool canDeleteMessageNow(CM.ChatMessage m) {
    if (m.deleted) return false;
    if (m.senderUid != currentUid) return false;
    final dt = m.createdAt;
    final diff = DateTime.now().toUtc().difference(dt);
    return diff <= deleteWindow;
  }

  // --------------------------------------------------------------------------
  // تعديل/حذف
  // --------------------------------------------------------------------------
  Future<void> editMessage({
    required String messageId,
    required String newBody,
  }) async {
    try {
      final convId = _openedConversationId;
      if (convId != null) {
        CM.ChatMessage? cur;
        final lst = _messagesByConv[convId];
        if (lst != null) {
          for (final m in lst) {
            if (m.id == messageId) {
              cur = m;
              break;
            }
          }
        }
        if (cur != null && !canEditMessageNow(cur)) {
          _setError(_trChat('انتهت صلاحية تعديل هذه الرسالة.'));
          _safeNotify();
          return;
        }
      }

      await _chat.editMessage(messageId: messageId, newBody: newBody);

      if (convId != null) {
        final list = List<CM.ChatMessage>.from(
          _messagesByConv[convId] ?? const [],
        );
        final i = list.indexWhere((m) => m.id == messageId);
        if (i != -1) {
          list[i] = list[i].copyWith(
            body: newBody,
            edited: true,
            editedAt: DateTime.now().toUtc(),
          );
          _messagesByConv[convId] = list;
          _safeNotify();
          await _persistMessages([list[i]]);
        }
      }
      _scheduleConversationsRefresh();
    } catch (e) {
      _setError(_trChat('تعذّر تعديل الرسالة: $e'));
      _safeNotify();
    }
  }

  Future<void> deleteMessage(String messageId) async {
    try {
      final convId = _openedConversationId;
      if (convId != null) {
        CM.ChatMessage? cur;
        final lst = _messagesByConv[convId];
        if (lst != null) {
          for (final m in lst) {
            if (m.id == messageId) {
              cur = m;
              break;
            }
          }
        }
        if (cur != null && !canDeleteMessageNow(cur)) {
          _setError(_trChat('انتهت صلاحية حذف هذه الرسالة.'));
          _safeNotify();
          return;
        }
      }

      await _chat.deleteMessage(messageId);

      if (convId != null) {
        final list = List<CM.ChatMessage>.from(
          _messagesByConv[convId] ?? const [],
        );
        final i = list.indexWhere((m) => m.id == messageId);
        if (i != -1) {
          list[i] = list[i].copyWith(
            deleted: true,
            deletedAt: DateTime.now().toUtc(),
            body: null,
          );
          _messagesByConv[convId] = list;
          _safeNotify();
          await _persistMessages([list[i]]);
        }
      }
      _scheduleConversationsRefresh();
    } catch (e) {
      _setError(_trChat('تعذّر حذف الرسالة: $e'));
      _safeNotify();
    }
  }

  // --------------------------------------------------------------------------
  // تعليم مقروئية
  // --------------------------------------------------------------------------
  Future<void> markConversationRead(String conversationId) async {
    DateTime? effective;
    if (_isOnline) {
      try {
        if (_allowRemoteHistory(conversationId)) {
          effective = await _chat.markReadUpToLatest(conversationId);
        } else {
          final lastReadable = _lastReadableMessage(conversationId);
          if (lastReadable != null) {
            await _chat.markReadUpTo(
              conversationId: conversationId,
              messageId: lastReadable.id,
              createdAt: lastReadable.createdAt,
            );
            effective = lastReadable.createdAt;
          }
        }
      } catch (_) {}
    }
    final ts = effective ??
        _myLastReadByConv[conversationId] ??
        DateTime.now().toUtc();
    _myLastReadByConv[conversationId] = ts;
    unawaited(_local.upsertRead(conversationId, ts));
    if (_isOnline) {
      unawaited(_rt.setLastRead(conversationId, ts));
    }
    _rt.setLocalLastRead(conversationId, ts);
    final i = _conversations.indexWhere((c) => c.id == conversationId);
    if (i != -1) {
      _conversations[i] = _conversations[i].copyWith(unreadCount: 0);
      _safeNotify();
      unawaited(_persistConversations([_conversations[i]]));
    }

    final list = _messagesByConv[conversationId];
    if (list != null && list.isNotEmpty) {
      final updated = List<CM.ChatMessage>.from(list);
      bool changed = false;
      for (var idx = 0; idx < updated.length; idx++) {
        final msg = updated[idx];
        final isMine = msg.senderUid == currentUid;
        final seen = !msg.createdAt.isAfter(ts);
        if (isMine && seen && msg.status != CM.ChatMessageStatus.read) {
          updated[idx] = msg.copyWith(status: CM.ChatMessageStatus.read);
          changed = true;
        }
      }
      if (changed) {
        _messagesByConv[conversationId] = updated;
        _safeNotify();
        try {
          final toPersist = updated
              .where(
                (m) =>
                    m.senderUid == currentUid &&
                    m.status == CM.ChatMessageStatus.read &&
                    !m.createdAt.isAfter(ts),
              )
              .toList();
          if (toPersist.isNotEmpty) {
            await _persistMessages(toPersist);
          }
        } catch (_) {}
      }
    }

    // تحديث حالة القراءة محليًا (cursor)
    try {
      final states = _readStatesByConv[conversationId] ?? <CM.ChatReadState>[];
      final idx = states.indexWhere((s) => s.userUid == currentUid);
      final lastReadable = _lastReadableMessage(conversationId);
      final lastId = lastReadable?.id ??
          (list?.isNotEmpty == true ? list!.first.id : null);
      final updatedState = CM.ChatReadState(
        conversationId: conversationId,
        userUid: currentUid,
        lastReadAt: ts,
        lastReadMessageId: lastId,
        lastDeliveredAt: ts,
        lastDeliveredMessageId: lastId,
      );
      if (idx == -1) {
        states.add(updatedState);
      } else {
        states[idx] = updatedState;
      }
      _readStatesByConv[conversationId] = states;
      await _local.upsertReadStates([updatedState]);
    } catch (_) {}

    if (_isOnline) {
      unawaited(_scheduleAttachmentCleanupForConversation(conversationId));
    }
  }

  CM.ChatMessageStatus computeStatusFor(
    String conversationId,
    CM.ChatMessage message,
  ) {
    if (message.senderUid != currentUid) return message.status;
    if (message.status == CM.ChatMessageStatus.failed ||
        message.status == CM.ChatMessageStatus.sending) {
      return message.status;
    }

    final participants =
        _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[];
    final targets = participants
        .where(
          (p) =>
              p.userUid.isNotEmpty &&
              p.userUid != currentUid &&
              !p.isDeleted &&
              (p.joinedAt == null || !p.joinedAt!.isAfter(message.createdAt)),
        )
        .map((p) => p.userUid)
        .toSet();
    if (targets.isEmpty) return CM.ChatMessageStatus.sent;

    final states =
        _readStatesByConv[conversationId] ?? const <CM.ChatReadState>[];
    DateTime msgTime = message.createdAt;

    bool deliveredAll = true;
    bool readAll = true;
    for (final uid in targets) {
      final st = states.firstWhere(
        (s) => s.userUid == uid,
        orElse: () => const CM.ChatReadState(
          conversationId: '',
          userUid: '',
        ),
      );
      final deliveredOk =
          st.lastDeliveredAt != null && !st.lastDeliveredAt!.isBefore(msgTime);
      final readOk = st.lastReadAt != null && !st.lastReadAt!.isBefore(msgTime);
      if (!deliveredOk) deliveredAll = false;
      if (!readOk) readAll = false;
    }

    if (readAll) return CM.ChatMessageStatus.read;
    if (deliveredAll) return CM.ChatMessageStatus.delivered;
    return CM.ChatMessageStatus.sent;
  }

  // تطبيق قراءة الآخرين على رسائلي
  Future<void> _applyReadsToOutgoing(String conversationId) async {
    final list = List<CM.ChatMessage>.from(
      _messagesByConv[conversationId] ?? const [],
    );
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.senderUid != currentUid) continue;
      final nextStatus = computeStatusFor(conversationId, m);
      if (nextStatus != m.status) {
        list[i] = m.copyWith(status: nextStatus);
        changed = true;
      }
    }
    if (changed) {
      _messagesByConv[conversationId] = list;
      _safeNotify();
      try {
        await _persistMessages(list);
      } catch (_) {}
    }
  }

  // --------------------------------------------------------------------------
  // بحث داخل المحادثة
  // --------------------------------------------------------------------------
  Future<List<CM.ChatMessage>> searchInConversation({
    required String conversationId,
    required String query,
    int limit = 100,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const <CM.ChatMessage>[];

    try {
      final list = await _chat.searchMessages(
        conversationId: conversationId,
        query: q,
        limit: limit,
      );
      return list;
    } catch (_) {
      final cached = await _local.getMessages(
        conversationId,
        accountId: _accountFilter,
        limit: 500,
      );
      final lower = q.toLowerCase();
      final filtered = cached.where((m) {
        final txt = (m.body ?? m.text).toLowerCase();
        return txt.contains(lower);
      }).toList();
      if (filtered.length > limit) {
        return filtered.sublist(0, limit);
      }
      return filtered;
    }
  }

  // Typing
  Timer? _typingPingDebounce;

  void setTyping(String conversationId, bool isTyping) {
    _typingPingDebounce?.cancel();
    _typingPingDebounce = Timer(const Duration(milliseconds: 400), () {
      if (_disposed) return;
      if (!_isOnline) return;
      _chat.pingTyping(conversationId, typing: isTyping);
    });
  }

  String displayForParticipant(String conversationId, String uid) {
    final parts =
        _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[];
    for (final p in parts) {
      if (p.userUid == uid) {
        final alias = _aliasByUser[p.userUid];
        return _displayLabelForParticipant(p, alias: alias);
      }
    }
    return _trChat('بدون رقم');
  }

  String _displayLabelForParticipant(
    ChatParticipantLocal p, {
    String? alias,
  }) {
    final aliasTrimmed = (alias ?? '').trim();
    if (aliasTrimmed.isNotEmpty) return aliasTrimmed;
    final displayName = (p.displayName ?? '').trim();
    if (displayName.isNotEmpty) return displayName;
    final nick = (p.nickname ?? '').trim();
    if (nick.isNotEmpty) {
      return ChatCodeUtils.isChatCode(nick) ? ChatCodeUtils.format(nick) : nick;
    }
    final code = (p.chatCode ?? '').trim();
    if (code.isNotEmpty) {
      return ChatCodeUtils.isChatCode(code) ? ChatCodeUtils.format(code) : code;
    }
    final email = (p.email ?? '').trim();
    final digits = ChatCodeUtils.normalize(email);
    if (ChatCodeUtils.isChatCode(digits)) return ChatCodeUtils.format(digits);
    if (email.isNotEmpty) return email;
    return _trChat('بدون رقم');
  }

  List<ChatParticipantLocal> participantsOf(String conversationId) {
    return List<ChatParticipantLocal>.from(
      _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[],
    );
  }

  List<String> displayNamesForTyping(
    String conversationId,
    Iterable<String> uids,
  ) {
    return [for (final u in uids) displayForParticipant(conversationId, u)];
  }

  ChatParticipantLocal? myParticipant(String conversationId) {
    final parts =
        _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[];
    for (final p in parts) {
      if (p.userUid == currentUid) return p;
    }
    return null;
  }

  bool isConversationArchived(String conversationId) {
    final p = myParticipant(conversationId);
    return p?.archived == true;
  }

  String? myRoleForConversation(String conversationId) {
    return myParticipant(conversationId)?.role;
  }

  // إنشاء DM / مجموعة
  Future<CM.ChatConversation> startDirectByEmail(String emailOrCode) async {
    final conv = await _chat.startDMWithEmail(emailOrCode);
    _ensureConversationVisible(
      conv,
      displayTitle: ChatCodeUtils.isChatCode(emailOrCode.trim())
          ? emailOrCode.trim()
          : null,
    );
    _scheduleConversationsRefresh();
    return conv;
  }

  Future<CM.ChatConversation> createGroup({
    required String title,
    required List<String> memberEmails,
  }) async {
    throw _trChat('تم إيقاف المحادثات الجماعية في هذا الإصدار.');
  }

  void _ensureConversationVisible(
    CM.ChatConversation conv, {
    String? displayTitle,
  }) {
    if (conv.id.isEmpty) return;
    final now = DateTime.now().toUtc();
    var normalized = conv.copyWith(
      lastMsgAt: conv.lastMsgAt ?? conv.updatedAt ?? now,
      updatedAt: conv.updatedAt ?? now,
    );
    final trimmed = displayTitle?.trim();
    if (!normalized.isGroup &&
        trimmed != null &&
        trimmed.isNotEmpty &&
        (normalized.title == null || normalized.title!.trim().isEmpty)) {
      normalized = normalized.copyWith(title: trimmed);
    }
    final idx = _conversations.indexWhere((c) => c.id == conv.id);
    if (idx == -1) {
      _conversations.insert(0, normalized);
    } else {
      _conversations[idx] = normalized;
    }

    if (trimmed != null && trimmed.isNotEmpty) {
      _displayTitleByConv[conv.id] = trimmed;
    }
    _safeNotify();
    unawaited(_persistConversations([normalized]));
  }

  Future<void> groupSetTitle({
    required String conversationId,
    required String title,
  }) async {
    throw _trChat('تم إيقاف المحادثات الجماعية في هذا الإصدار.');
  }

  Future<void> groupSetFrozen({
    required String conversationId,
    required bool isFrozen,
    required bool adminsOnly,
  }) async {
    throw _trChat('تم إيقاف المحادثات الجماعية في هذا الإصدار.');
  }

  Future<void> groupSetMemberRole({
    required String conversationId,
    required String targetUid,
    required String role,
  }) async {
    throw _trChat('تم إيقاف المحادثات الجماعية في هذا الإصدار.');
  }

  Future<void> groupRemoveMember({
    required String conversationId,
    required String targetUid,
  }) async {
    throw _trChat('تم إيقاف المحادثات الجماعية في هذا الإصدار.');
  }

  Future<void> groupDelete(String conversationId) async {
    throw _trChat('تم إيقاف المحادثات الجماعية في هذا الإصدار.');
  }

  // --------------------------------------------------------------------------
  // رفع صورة مفردة
  // --------------------------------------------------------------------------
  String _safeFileName(String name) {
    final s = name.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_\.\-]'), '_');
    return s.isEmpty ? 'img_${DateTime.now().millisecondsSinceEpoch}.jpg' : s;
  }

  String _guessMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<(String url, String storagePath)> uploadSingleImageWithMessageId(
    String conversationId,
    String messageId,
    File file,
  ) async {
    final base = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'image.jpg';
    var name = _safeFileName(base);
    if (!name.contains('.')) name = '$name.jpg';
    final mime = _guessMime(name);

    final storageName = 'attachments/$conversationId/$messageId/$name';
    final res = await _storage.uploadFile(
      file: file,
      name: storageName,
      bucketId: storageBucketChat,
      mimeType: mime,
    );
    final fileId = res['id']?.toString() ?? '';
    final url = await _signedOrPublicUrl(storageBucketChat, fileId);
    return (url, fileId);
  }

  @Deprecated(
    'Use uploadSingleImageWithMessageId(conversationId, messageId, file)',
  )
  Future<(String url, String storagePath)> uploadSingleImage(
    String conversationId,
    File file,
  ) async {
    final rnd = Random().nextInt(1 << 32);
    final base = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : 'image.jpg';
    var name = _safeFileName(base);
    if (!name.contains('.')) name = '$name.jpg';
    final mime = _guessMime(name);

    final storageName = 'attachments/$conversationId/legacy/$rnd/$name';
    final res = await _storage.uploadFile(
      file: file,
      name: storageName,
      bucketId: storageBucketChat,
      mimeType: mime,
    );
    final fileId = res['id']?.toString() ?? '';
    final url = await _signedOrPublicUrl(storageBucketChat, fileId);
    return (url, fileId);
  }

  // --------------------------------------------------------------------------
  // ✅ Prefetch مرفقات الرسائل الظاهرة (لا يحدّث الـSQLite، يضمن وجود الملف محليًا)
  // --------------------------------------------------------------------------
  Future<void> prefetchVisibleAttachments(
    String conversationId, {
    int maxMessages = 24,
  }) async {
    final msgs = _messagesByConv[conversationId] ?? const <CM.ChatMessage>[];
    final allowRemote = _allowRemoteHistory(conversationId);
    int processed = 0;
    for (final m in msgs) {
      if (processed >= maxMessages) break;
      processed++;

      if (!allowRemote && !_recentIncomingMessageIds.containsKey(m.id)) {
        continue;
      }

      bool allCached = true;
      final atts = _attachmentsOf(m);
      for (final a in atts) {
        // حاول الحصول على URL، وإلا اشتقّه من bucket/path
        String? url = _attUrl(a);
        final bucket = _attBucket(a);
        final path = _attPath(a);
        if ((url == null || url.isEmpty) &&
            bucket != null &&
            path != null &&
            bucket.isNotEmpty &&
            path.isNotEmpty) {
          try {
            url = await _signedOrPublicUrl(bucket, path);
          } catch (_) {}
        }
        if (url == null || url.isEmpty) {
          allCached = false;
          continue;
        }
        String? localPath;
        if (bucket != null &&
            path != null &&
            bucket.isNotEmpty &&
            path.isNotEmpty) {
          localPath = await _attCache.ensureFileForStorage(
            bucket,
            path,
            url: url,
          );
        } else {
          localPath = await _attCache.ensureFileFor(url);
        }
        if (localPath == null || localPath.isEmpty) {
          allCached = false;
          continue;
        }
        final expectedSize = _attSizeBytes(a);
        if (expectedSize != null) {
          try {
            final actual = await File(localPath).length();
            if (actual != expectedSize) {
              allCached = false;
              continue;
            }
          } catch (_) {}
        }
        final attId = _attId(a);
        if (attId != null && attId.isNotEmpty) {
          unawaited(_recordAttachmentDownloaded(attId, conversationId));
        }
      }
      // بعد محاولة تنزيل مرفقات الرسالة، أزلها من قائمة "الواردة حديثًا"
      if (!allowRemote && allCached) {
        _recentIncomingMessageIds.remove(m.id);
      }
    }
    _pruneRecentIncoming();
    if (_isOnline) {
      await _maybeMarkDeliveredAfterDownloads(conversationId);
      await _scheduleAttachmentCleanupForConversation(conversationId);
    }
  }

  // Helpers لاستخراج خصائص المرفق مهما كان نوعه (Map أو كلاس نموذج)
  List<dynamic> _attachmentsOf(CM.ChatMessage m) {
    try {
      final v = (m as dynamic).attachments;
      if (v is List) return v;
    } catch (_) {}
    return const [];
  }

  String? _attBucket(dynamic a) {
    try {
      final v = (a as dynamic).bucket;
      if (v != null) return v.toString();
    } catch (_) {}
    if (a is Map) return a['bucket']?.toString();
    return null;
  }

  String? _attPath(dynamic a) {
    try {
      final v = (a as dynamic).path;
      if (v != null) return v.toString();
    } catch (_) {}
    if (a is Map) return a['path']?.toString();
    return null;
  }

  String? _attUrl(dynamic a) {
    try {
      final v = (a as dynamic).url;
      if (v != null) return v.toString();
    } catch (_) {}
    if (a is Map) return a['url']?.toString();
    return null;
  }

  String? _attFileId(dynamic a) {
    try {
      final extra = (a as dynamic).extra;
      if (extra is Map) {
        final v = extra['file_id']?.toString();
        if (v != null && v.trim().isNotEmpty) return v.trim();
        final v2 = extra['fileId']?.toString();
        if (v2 != null && v2.trim().isNotEmpty) return v2.trim();
      }
    } catch (_) {}
    if (a is Map && a['file_id'] != null) {
      final v = a['file_id']?.toString();
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  String? _attId(dynamic a) {
    try {
      final v = (a as dynamic).id;
      if (v != null) {
        final s = v.toString().trim();
        if (s.isNotEmpty) return s;
      }
    } catch (_) {}
    if (a is Map) {
      final v = a['id']?.toString().trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  int? _attSizeBytes(dynamic a) {
    try {
      final v = (a as dynamic).sizeBytes;
      if (v is int) return v;
    } catch (_) {}
    if (a is Map) {
      final v = a['size_bytes'];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
    }
    return null;
  }

  Future<void> _seedLocalAttachmentsFromSent(
    List<CM.ChatMessage> sent,
    List<File> localFiles,
  ) async {
    if (sent.isEmpty || localFiles.isEmpty) return;
    final byName = <String, File>{};
    for (final f in localFiles) {
      byName[p.basename(f.path)] = f;
    }
    for (final m in sent) {
      final atts = _attachmentsOf(m);
      if (atts.isEmpty) continue;
      for (final a in atts) {
        final fid = _attFileId(a);
        if (fid == null || fid.isEmpty) continue;
        String? url;
        try {
          final v = (a as dynamic).url;
          if (v != null) url = v.toString();
        } catch (_) {}
        if (url == null || url.trim().isEmpty) {
          try {
            final v = (a as dynamic).signedUrl;
            if (v != null) url = v.toString();
          } catch (_) {}
        }
        url ??= _storage.publicFileUrl(fid);
        File? local;
        try {
          final extra = (a as dynamic).extra;
          if (extra is Map && extra['local_path'] is String) {
            final lp = (extra['local_path'] as String).trim();
            if (lp.isNotEmpty && File(lp).existsSync()) {
              local = File(lp);
            }
          }
        } catch (_) {}
        local ??= byName[p.basename(_attPath(a) ?? '')];
        if (local == null || !local.existsSync()) continue;
        await _attCache.seedFromLocalFile(url, local);
      }
    }
  }

  bool _allowRemoteHistory(String conversationId) {
    return true;
  }

  bool allowRemoteAttachmentDownload(
    String conversationId,
    CM.ChatMessage message,
  ) {
    if (_allowRemoteHistory(conversationId)) return true;
    if (message.senderUid == currentUid) return true;
    if (_isMessageAttachmentsCached(message)) return true;
    return _recentIncomingMessageIds.containsKey(message.id);
  }

  void _pruneRecentIncoming() {
    if (_recentIncomingMessageIds.isEmpty) return;
    final cutoff = DateTime.now().toUtc().subtract(const Duration(hours: 24));
    _recentIncomingMessageIds.removeWhere((_, ts) => ts.isBefore(cutoff));
  }

  bool _isAttachmentCached(dynamic a) {
    // مسار محلي صريح
    try {
      final extra = (a as dynamic).extra;
      if (extra is Map && extra['local_path'] is String) {
        final lp = (extra['local_path'] as String).trim();
        if (lp.isNotEmpty && File(lp).existsSync()) return true;
      }
    } catch (_) {}
    // file_id → URL ثابت
    try {
      final extra = (a as dynamic).extra;
      if (extra is Map) {
        final fid = extra['file_id']?.toString().trim();
        if (fid != null && fid.isNotEmpty) {
          final url = _storage.publicFileUrl(fid);
          if (_attCache.localPathSyncIfAny(url) != null) return true;
        }
      }
    } catch (_) {}
    // url مباشر
    final url = _attUrl(a);
    if (url != null && url.isNotEmpty) {
      if (_attCache.localPathSyncIfAny(url) != null) return true;
    }
    // path محلي محتمل
    final pth = _attPath(a);
    if (pth != null && pth.isNotEmpty && File(pth).existsSync()) return true;
    return false;
  }

  bool _isMessageAttachmentsCached(CM.ChatMessage m) {
    final atts = _attachmentsOf(m);
    if (atts.isEmpty) return true;
    for (final a in atts) {
      if (!_isAttachmentCached(a)) return false;
    }
    return true;
  }

  CM.ChatMessage? _lastReadableMessage(String conversationId) {
    final list = _messagesByConv[conversationId] ?? const <CM.ChatMessage>[];
    if (list.isEmpty) return null;
    final sorted = List<CM.ChatMessage>.from(list)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    CM.ChatMessage? lastOk;
    for (final m in sorted) {
      if (!_isMessageAttachmentsCached(m)) break;
      lastOk = m;
    }
    return lastOk;
  }

  CM.ChatReadState? _myReadState(String conversationId) {
    final states =
        _readStatesByConv[conversationId] ?? const <CM.ChatReadState>[];
    return states.firstWhere(
      (s) => s.userUid == currentUid,
      orElse: () => const CM.ChatReadState(conversationId: '', userUid: ''),
    );
  }

  Future<void> _maybeMarkDeliveredAfterDownloads(String conversationId) async {
    if (!_isOnline) return;
    final list = _messagesByConv[conversationId] ?? const <CM.ChatMessage>[];
    CM.ChatMessage? last;
    for (final m in list) {
      if (m.senderUid == currentUid) continue;
      if (m.id.isEmpty || m.id.startsWith('local-')) continue;
      if (!_isMessageAttachmentsCached(m)) continue;
      if (last == null || m.createdAt.isAfter(last.createdAt)) {
        last = m;
      }
    }
    if (last == null) return;
    final st = _myReadState(conversationId);
    final deliveredOk = st?.lastDeliveredAt != null &&
        !st!.lastDeliveredAt!.isBefore(last.createdAt);
    if (deliveredOk) return;
    try {
      await _chat.markDeliveredUpTo(
        conversationId: conversationId,
        messageId: last.id,
        createdAt: last.createdAt,
      );
      final states = _readStatesByConv[conversationId] ?? <CM.ChatReadState>[];
      final idx = states.indexWhere((s) => s.userUid == currentUid);
      final updated = CM.ChatReadState(
        conversationId: conversationId,
        userUid: currentUid,
        lastDeliveredAt: last.createdAt,
        lastDeliveredMessageId: last.id,
        lastReadAt: st?.lastReadAt,
        lastReadMessageId: st?.lastReadMessageId,
      );
      if (idx == -1) {
        states.add(updated);
      } else {
        states[idx] = updated;
      }
      _readStatesByConv[conversationId] = states;
      await _local.upsertReadStates([updated]);
      _applyReadsToOutgoing(conversationId);
    } catch (_) {}
  }

  Future<void> _enqueueReceipt({
    required String kind,
    required String attachmentId,
    required String conversationId,
  }) async {
    await _enqueueOutbox(
      localId: 'att_${kind}_$attachmentId',
      conversationId: conversationId,
      kind: kind,
      body: attachmentId,
    );
  }

  Future<void> _recordAttachmentDownloaded(
    String attachmentId,
    String conversationId,
  ) async {
    final dev = await _ensureDeviceId();
    if (dev == null || dev.trim().isEmpty) return;
    if (!_isOnline) {
      await _enqueueReceipt(
        kind: 'att_downloaded',
        attachmentId: attachmentId,
        conversationId: conversationId,
      );
      return;
    }
    try {
      await _chat.markAttachmentDownloaded(
        attachmentId: attachmentId,
        deviceId: dev,
      );
    } catch (_) {
      await _enqueueReceipt(
        kind: 'att_downloaded',
        attachmentId: attachmentId,
        conversationId: conversationId,
      );
    }
  }

  Future<void> _recordAttachmentOpened(
    String attachmentId,
    String conversationId,
  ) async {
    final dev = await _ensureDeviceId();
    if (dev == null || dev.trim().isEmpty) return;
    if (!_isOnline) {
      await _enqueueReceipt(
        kind: 'att_opened',
        attachmentId: attachmentId,
        conversationId: conversationId,
      );
      return;
    }
    try {
      await _chat.markAttachmentOpened(
        attachmentId: attachmentId,
        deviceId: dev,
      );
    } catch (_) {
      await _enqueueReceipt(
        kind: 'att_opened',
        attachmentId: attachmentId,
        conversationId: conversationId,
      );
    }
  }

  Future<void> markAttachmentOpenedForMessage(
    String conversationId,
    CM.ChatMessage message,
  ) async {
    final atts = _attachmentsOf(message);
    for (final a in atts) {
      final id = _attId(a);
      if (id != null && id.isNotEmpty) {
        await _recordAttachmentOpened(id, conversationId);
      }
    }
  }

  void _startAttachmentCleanupWorker() {
    // Purge is handled server-side via cron + receipts.
  }

  Future<void> _scheduleAttachmentCleanupForConversation(
    String conversationId,
  ) async {
    return;
  }

  // --------------------------------------------------------------------------
  // ✅ تحويل الرسالة إلى محادثات/مجموعات أخرى
  // --------------------------------------------------------------------------
  Future<void> forwardMessage({
    required CM.ChatMessage message,
    required List<String> targetConversationIds,
  }) async {
    if (targetConversationIds.isEmpty) return;

    final originalText = (message.body ?? message.text).trim();
    final label = originalText.isNotEmpty
        ? _trChat('تم تحويلها:\n$originalText')
        : _trChat('تم تحويلها');

    // جهّز ملفات الصور إن وجدت
    final files = <File>[];
    final atts = _attachmentsOf(message);
    for (final a in atts) {
      final t = (() {
        try {
          final v = (a as dynamic).type?.toString();
          return v ?? (a is Map ? a['type']?.toString() : null);
        } catch (_) {
          return (a is Map) ? a['type']?.toString() : null;
        }
      })();
      final isImage = (t == null) || t.toLowerCase() == 'image';
      if (!isImage) continue;

      // حدّد URL نهائي
      String? url = _attUrl(a);
      final bucket = _attBucket(a);
      final path = _attPath(a);
      if ((url == null || url.isEmpty) &&
          bucket != null &&
          path != null &&
          bucket.isNotEmpty &&
          path.isNotEmpty) {
        try {
          url = await _signedOrPublicUrl(bucket, path);
        } catch (_) {}
      }
      if (url == null || url.isEmpty) continue;

      try {
        // يعيد مسار الملف المحلي عند اكتمال/توفر التنزيل
        final String? lp = await _attCache.ensureFileFor(url);
        if (lp != null && lp.isNotEmpty) {
          files.add(File(lp));
        }
      } catch (_) {
        // تجاهل أي فشل لملف واحد
      }
    }

    for (final cid in targetConversationIds) {
      try {
        if (files.isEmpty) {
          await sendText(conversationId: cid, text: label);
        } else {
          await sendImages(
            conversationId: cid,
            files: files,
            optionalText: label,
          );
        }
      } catch (e) {
        _setError(_trChat('تعذّر تحويل الرسالة: $e'));
        _safeNotify();
      }
    }
  }

  // تنظيف
  @override
  void dispose() {
    _disposed = true;
    _queuedAuthSnapshot = null;
    _authSyncScheduled = false;
    _bootstrapInFlight = null;
    _bootstrapSessionKey = null;
    try {
      _roomMsgsSub?.cancel();
      _roomMsgsSub = null;
    } catch (_) {}
    try {
      _typingSub?.cancel();
      _typingSub = null;
    } catch (_) {}
    try {
      _readsSub?.cancel();
    } catch (_) {}
    _readsSub = null;

    try {
      _listDebounce?.cancel();
    } catch (_) {}
    _typingPingDebounce?.cancel();

    try {
      _rtConvSub?.cancel();
      _rtConvSub = null;
    } catch (_) {}
    try {
      _rtPartSub?.cancel();
      _rtPartSub = null;
    } catch (_) {}
    try {
      _rtMsgSub?.cancel();
      _rtMsgSub = null;
    } catch (_) {}
    try {
      _netSub?.cancel();
      _netSub = null;
    } catch (_) {}
    try {
      _outboxRetryTimer?.cancel();
    } catch (_) {}
    _outboxRetryTimer = null;
    try {
      _attachmentCleanupTimer?.cancel();
      _attachmentCleanupTimer = null;
    } catch (_) {}
    try {
      _deviceRegTimer?.cancel();
      _deviceRegTimer = null;
    } catch (_) {}

    _aliasByUser.clear();
    super.dispose();
  }
} // ← أغلق صنف ChatProvider هنا فقط

// ضع تعريف ChatParticipantLocal خارج ChatProvider (تعريف وحيد)
class ChatParticipantLocal {
  final String conversationId;
  final String userUid;
  final String? email;
  final DateTime? joinedAt;
  final String? nickname;
  final String? displayName;
  final String? chatCode;
  final String? role;
  final bool archived;
  final bool pinned;
  final bool blocked;
  final bool isDeleted;

  const ChatParticipantLocal({
    required this.conversationId,
    required this.userUid,
    this.email,
    this.joinedAt,
    this.nickname,
    this.displayName,
    this.chatCode,
    this.role,
    this.archived = false,
    this.pinned = false,
    this.blocked = false,
    this.isDeleted = false,
  });

  factory ChatParticipantLocal.fromMap(Map<String, dynamic> m) {
    DateTime? _parse(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v.toString()).toUtc();
      } catch (_) {
        return null;
      }
    }

    bool _toBool(dynamic v) {
      if (v == null) return false;
      if (v is bool) return v;
      if (v is num) return v != 0;
      final s = v.toString().toLowerCase().trim();
      return s == 'true' || s == '1' || s == 'yes';
    }

    return ChatParticipantLocal(
      conversationId: m['conversation_id']?.toString() ?? '',
      userUid: m['user_uid']?.toString() ?? '',
      email: m['email']?.toString(),
      joinedAt: _parse(m['joined_at']),
      nickname: m['nickname']?.toString(),
      displayName:
          m['display_name']?.toString() ?? m['displayName']?.toString(),
      chatCode: m['chat_code']?.toString() ?? m['chatCode']?.toString(),
      role: m['role']?.toString(),
      archived: _toBool(m['archived']),
      pinned: _toBool(m['pinned']),
      blocked: _toBool(m['blocked']),
      isDeleted: _toBool(m['is_deleted']),
    );
  }

  factory ChatParticipantLocal.fallback(String conversationId) =>
      ChatParticipantLocal(
        conversationId: conversationId,
        userUid: '',
        email: null,
      );

  Map<String, dynamic> toMap() {
    return {
      'conversation_id': conversationId,
      'user_uid': userUid,
      'email': email,
      'joined_at': joinedAt?.toUtc().toIso8601String(),
      'nickname': nickname,
      'display_name': displayName,
      'chat_code': chatCode,
      'role': role,
      'archived': archived,
      'pinned': pinned,
      'blocked': blocked,
      'is_deleted': isDeleted,
    };
  }
}
