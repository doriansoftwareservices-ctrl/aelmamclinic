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

import 'package:aelmamclinic/local/chat_local_store.dart';
import 'package:aelmamclinic/models/chat_invitation.dart';
import 'package:aelmamclinic/models/chat_models.dart' as CM;
import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/services/chat_service.dart';
import 'package:aelmamclinic/services/chat_realtime_notifier.dart';
import 'package:aelmamclinic/services/attachment_cache.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';
import 'package:aelmamclinic/utils/logger.dart';
import 'package:aelmamclinic/utils/app_error_reporter.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider();

  // جداول
  static const String tableParticipants = 'chat_participants';
  static const String tableAccountUsers = 'account_users';
  static const String tableProfiles = 'profiles';
  static const String tableReads = 'chat_reads';
  static const String storageBucketChat = ChatService.attachmentsBucket;

  // نوافذ صلاحيات
  static const Duration editWindow = Duration(hours: 2);
  static const Duration deleteWindow = Duration(hours: 12);

  // خدمات
  GraphQLClient get _gql => NhostGraphqlService.client;
  final NhostStorageService _storage = NhostStorageService();
  final ChatService _chat = ChatService.instance;
  final ChatRealtimeNotifier _rt = ChatRealtimeNotifier.instance;
  final AttachmentCache _attCache = AttachmentCache.instance; // ✅
  final Map<String, ({String url, DateTime expiresAt})> _signedUrlCache = {};

  // هوية
  String get currentUid => NhostManager.client.auth.currentUser?.id ?? '';
  String? _myEmailCache;

  // حالة عامة
  bool ready = false;
  bool busy = false;
  String? lastError;

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
  final Map<String, String> _displayTitleByConv = {};
  String displayTitleOf(String conversationId) =>
      _displayTitleByConv[conversationId] ?? 'محادثة';

  String? _supportConversationId;
  String _supportDisplayName = 'خدمة العملاء';
  bool _supportReady = false;

  String? get supportConversationId => _supportConversationId;
  String get supportDisplayName => _supportDisplayName;
  bool isSupportConversation(String conversationId) =>
      _supportConversationId == conversationId;

  final Map<String, List<CM.ChatMessage>> _messagesByConv = {};
  List<CM.ChatMessage> messagesOf(String conversationId) =>
      List.unmodifiable(_messagesByConv[conversationId] ?? const []);

  final Map<String, DateTime?> _olderCursorByConv = {};
  final Map<String, DateTime?> _myLastReadByConv = {};

  String? _openedConversationId;

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

  // اشتراكات
  StreamSubscription<List<CM.ChatMessage>>? _roomMsgsSub;
  StreamSubscription<Map<String, dynamic>>? _typingSub;
  StreamSubscription<QueryResult>? _readsSub;

  // RealtimeNotifier subs
  StreamSubscription<void>? _rtConvSub;
  StreamSubscription<void>? _rtPartSub;
  StreamSubscription<Map<String, dynamic>>? _rtMsgSub;

  // Anti-dup / Throttling
  bool _listLoading = false;
  int _listRev = 0;
  Timer? _listDebounce;
  Timer? _outboxTimer;

  // حماية التخلص
  bool _disposed = false;
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _setError(String message) {
    lastError = message;
    AppErrorReporter.report(message);
  }

  void _scheduleConversationsRefresh() {
    _listDebounce?.cancel();
    _listDebounce = Timer(const Duration(milliseconds: 250), () async {
      if (_disposed) return;
      await refreshConversations();
    });
  }

  Future<void> _loadLocalSnapshot() async {
    try {
      final localConvs = await _local.getConversations();
      final visibleConvs = localConvs.where((c) => !c.isDeleted).toList();
      if (visibleConvs.isEmpty) return;

      final tmpParts = <String, List<ChatParticipantLocal>>{};
      final tmpReads = <String, List<CM.ChatReadState>>{};
      final tmpDisplay = <String, String>{};

      for (final c in visibleConvs) {
        final partsRaw = await _local.getParticipants(c.id);
        final parts = partsRaw
            .map((m) => ChatParticipantLocal.fromMap(m))
            .toList();
        tmpParts[c.id] = parts;

        final reads = await _local.getReadStates(c.id);
        tmpReads[c.id] = reads;

        if (c.isGroup) {
          tmpDisplay[c.id] =
              (c.title?.trim().isNotEmpty == true) ? c.title!.trim() : 'مجموعة';
        } else {
          final other = parts.firstWhere(
            (p) => p.userUid != currentUid,
            orElse: () => parts.isNotEmpty
                ? parts.first
                : ChatParticipantLocal.fallback(c.id),
          );
          final nick = (other.nickname ?? '').trim();
          tmpDisplay[c.id] = nick.isNotEmpty
              ? nick
              : ((other.email?.isNotEmpty == true)
                  ? other.email!
                  : 'بدون بريد');
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
      _conversations
        ..clear()
        ..addAll(visibleConvs);

      _safeNotify();
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
      _setError('لا يوجد مستخدم مسجّل الدخول.');
      busy = false;
      _safeNotify();
      return;
    }
    busy = true;
    _safeNotify();
    try {
      await _primeMyEmail();
      await _loadLocalSnapshot();
      final accId = accountId ??
          await fetchAccountIdForCurrentUser(isSuperAdmin: isSuperAdmin);
      final accountFilter =
          (accId == null || accId.trim().isEmpty) ? null : accId.trim();

      if (accountFilter == null && !isSuperAdmin) {
        _setError('لا يمكن تحميل المحادثات لأن الحساب الحالي غير محدد.');
        return;
      }

      if (accountFilter == null && isSuperAdmin) {
        _rpcWarn(
          'super_admin_missing_account_filter',
          StateError('no account binding for super admin; using global view'),
        );
      }

      // بدء Realtime الموحّد
      try {
        await _rt.start(accountId: accountFilter, myUid: currentUid);
      } catch (error, stackTrace) {
        debugPrint(
          'ChatProvider.bootstrap: فشل بدء Realtime: $error\n$stackTrace',
        );
        _setError('تعذّرت تهيئة المحادثات، حاول مرة أخرى لاحقًا.');
        return;
      }

      // تحميل القائمة والمشاركين مبدئياً
      await _loadMyConversationsAndParticipants();
      await refreshInvitations();
      if (_disposed) return;

      // الاشتراك في التيارات الموحّدة
      _rtConvSub?.cancel();
      _rtConvSub = _rt.conversationsTicks.listen((_) {
        if (_disposed) return;
        _scheduleConversationsRefresh();
      });

      _rtPartSub?.cancel();
      _rtPartSub = _rt.participantsTicks.listen((_) {
        if (_disposed) return;
        _scheduleConversationsRefresh();
      });

      _rtMsgSub?.cancel();
      _rtMsgSub = _rt.messageEvents.listen((payload) {
        if (_disposed) return;
        try {
          _handleMessageInsert(payload);
        } catch (_) {}
        _scheduleConversationsRefresh();
      });

      ready = true;
      _startOutboxWorker();
    } catch (e, stackTrace) {
      debugPrint('ChatProvider.bootstrap: حدث خطأ غير متوقّع: $e');
      debugPrint('$stackTrace');
      lastError ??= 'حدث خطأ غير متوقع أثناء تجهيز المحادثات.';
      if (lastError != null) {
        AppErrorReporter.report(lastError!);
      }
    } finally {
      busy = false;
      _safeNotify();
    }
  }

  Future<void> ensureSupportConversation({bool force = false}) async {
    if (_disposed) return;
    if (_supportReady && !force) return;

    try {
      final agent = await _chat.fetchSupportAgent();
      if (agent == null) {
        _supportReady = true;
        return;
      }

      final uid = agent['user_uid'] ?? '';
      final name = agent['display_name'] ?? 'خدمة العملاء';
      if (uid.isEmpty) {
        _supportReady = true;
        return;
      }

      _supportDisplayName = name;

      final conv = await _chat.startDMWithUid(uid);
      _supportConversationId = conv.id;
      _displayTitleByConv[conv.id] = name;
    } catch (e, st) {
      _rpcWarn('ensureSupportConversation failed', e, st);
    } finally {
      _supportReady = true;
      _safeNotify();
    }
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
    if (_listLoading) {
      _listRev++;
      return;
    }
    _listLoading = true;
    final myRev = ++_listRev;

    try {
      final List<CM.ConversationListItem> overview =
          await _chat.fetchMyConversationsOverview();
      final convIds = overview
          .map((item) => item.conversation.id)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (convIds.isEmpty) {
        if (myRev == _listRev) {
          if (_conversations.isEmpty) {
            _participantsByConv..clear();
            _displayTitleByConv..clear();
            _myLastReadByConv..clear();
            _safeNotify();
          }
        }
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
            (item) => item.conversation.copyWith(
              unreadCount: item.unreadCount,
            ),
          )
          .toList();

      // عنونة العرض
      final aliasByUser = await _chat.fetchAliasMap();
      final tmpDisplay = <String, String>{};
      for (final c in serverList) {
        final cid = c.id.trim();
        if (cid.isEmpty) continue;

        if (c.isGroup) {
          tmpDisplay[cid] =
              (c.title?.trim().isNotEmpty == true) ? c.title!.trim() : 'مجموعة';
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
          if (alias != null && alias.trim().isNotEmpty) {
            tmpDisplay[cid] = alias.trim();
            continue;
          }
          final nick = (other.nickname ?? '').trim();
          tmpDisplay[cid] = nick.isNotEmpty
              ? nick
              : ((other.email?.isNotEmpty == true)
                  ? other.email!
                  : 'بدون بريد');
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
        final uc = (openedId == srv.id) ? 0 : serverUc;

        return srv.copyWith(
          lastMsgAt: effAt,
          lastMsgSnippet: effSnippet,
          unreadCount: uc,
        );
      }

      final merged = <CM.ChatConversation>[];
      for (final c in serverList) {
        merged.add(_mergeConv(c, prevById[c.id]));
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
        await _local.upsertConversations(merged);
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
    try {
      final list = await _chat.fetchMyGroupInvitations();
      if (_disposed) return;
      _invitations
        ..clear()
        ..addAll(list);
      _safeNotify();
    } catch (e, st) {
      _rpcWarn('fetchMyGroupInvitations failed', e, st);
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
    if (trimmed.isEmpty) {
      await _chat.removeAlias(other.userUid);
    } else {
      await _chat.setAlias(targetUid: other.userUid, alias: trimmed);
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
      _setError('تعذر تحديث الأرشفة: $e');
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

    if (archived) {
      _conversations.removeWhere((c) => c.id == conversationId);
    }
    _safeNotify();
  }

  Future<void> deleteConversationForMe(String conversationId) async {
    try {
      await _chat.deleteConversationForMe(conversationId: conversationId);
    } catch (e) {
      _setError('تعذر حذف المحادثة: $e');
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
  }

  Future<Map<String, dynamic>> _runQuery(
    String doc,
    Map<String, dynamic> variables,
  ) async {
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

    final createdAt =
        DateTime.tryParse((rec['created_at'] ?? '').toString())?.toUtc() ??
            DateTime.now().toUtc();
    final senderUid = (rec['sender_uid'] ?? '').toString();
    final body = ((rec['body'] ?? rec['text']) ?? '').toString();
    final snippet = _trimSnippet(body.isEmpty ? 'رسالة' : body);

    _fastBumpConversationOnNewMessage(
      cid: cid,
      createdAt: createdAt,
      snippet: snippet,
      fromUid: senderUid,
    );
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
    var uc = c.unreadCount ?? 0;
    if (fromUid != currentUid) {
      final lr = _myLastReadByConv[cid];
      if (lr == null || createdAt.isAfter(lr)) {
        uc = (uc + 1).clamp(1, 9999);
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

    unawaited(_local.upsertConversations([c]));
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
    } catch (_) {}
  }

  Future<void> openConversation(String conversationId) async {
    if (conversationId.isEmpty || _disposed) return;

    if (_openedConversationId == conversationId && _roomMsgsSub != null) {
      await markConversationRead(conversationId);
      await _applyReadsToOutgoing(conversationId);
      return;
    }

    _openedConversationId = conversationId;

    final cached = await _local.getMessages(conversationId, limit: 40);
    if (_disposed) return;
    _messagesByConv[conversationId] = cached;
    _olderCursorByConv[conversationId] =
        cached.isNotEmpty ? cached.last.createdAt : null;
    _safeNotify();

    await _refreshReadStatesForConversation(conversationId);

    // ✅ حمّل دفعة حديثة
    await loadMoreMessages(conversationId);
    if (_disposed) return;

    // ✅ Prefetch للرسائل الظاهرة (صور فقط غالبًا)
    unawaited(prefetchVisibleAttachments(conversationId, maxMessages: 30));

    try {
      await _roomMsgsSub?.cancel();
    } catch (_) {}
    _roomMsgsSub = _chat.watchMessages(conversationId).listen(
      (remoteList) async {
        if (_disposed) return;
        final latest = List<CM.ChatMessage>.from(remoteList.reversed);

        await _local.upsertMessages(latest);
        if (_disposed) return;

        _messagesByConv[conversationId] = latest;
        _olderCursorByConv[conversationId] = latest.isNotEmpty
            ? latest.last.createdAt
            : _olderCursorByConv[conversationId];

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
        _setError('Realtime error: $e');
        _safeNotify();
      },
    );

    try {
      await _typingSub?.cancel();
    } catch (_) {}
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
    _readsSub = _gql
        .subscribe(
          SubscriptionOptions(
            document: gql(readsSubDoc),
            variables: {'cid': conversationId},
            fetchPolicy: FetchPolicy.noCache,
          ),
        )
        .listen((_) => _refreshReadStatesForConversation(conversationId));

    await markConversationRead(conversationId);
    await _applyReadsToOutgoing(conversationId);
  }

  Future<void> closeConversation() async {
    _openedConversationId = null;
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
    _outboxTimer?.cancel();
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
    try {
      final DateTime? before = _olderCursorByConv[conversationId];

      final listDesc = await _fetchRecentBatchFromBackend(
        conversationId: conversationId,
        limit: 40,
        before: before,
      );

      final incoming = List<CM.ChatMessage>.from(listDesc.reversed);

      await _local.upsertMessages(incoming);

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

      if (incoming.isNotEmpty) {
        _olderCursorByConv[conversationId] = incoming.last.createdAt;
      }

      _safeNotify();

      await _applyReadsToOutgoing(conversationId);
    } catch (e) {
      final DateTime? before = _olderCursorByConv[conversationId];

      List<CM.ChatMessage> cached;
      if (before != null) {
        cached = await _local.getMessages(
          conversationId,
          beforeIso: before.toUtc().toIso8601String(),
          limit: 40,
        );
      } else {
        cached = await _local.getMessages(conversationId, limit: 40);
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
        _setError('تعذّر تحميل الرسائل: $e');
        _safeNotify();
      }
    }
  }

  // --------------------------------------------------------------------------
  // إرسال نص/صور
  // --------------------------------------------------------------------------
  void _startOutboxWorker() {
    _outboxTimer?.cancel();
    _outboxTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_disposed) return;
      unawaited(_flushOutbox());
    });
    unawaited(_flushOutbox());
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
    final payload = <String, dynamic>{
      'local_id': localId,
      'conversation_id': conversationId,
      'kind': kind,
      'body': body,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'reply_to_message_id': replyToMessageId,
      'reply_to_snippet': replyToSnippet,
      'mentions_json': mentions == null ? null : jsonEncode(mentions),
      'attachments_json':
          attachmentPaths == null ? null : jsonEncode(attachmentPaths),
      'status': 'queued',
      'error': null,
    };
    await _local.upsertOutboxMessage(payload);
  }

  Future<void> _flushOutbox() async {
    if (_disposed) return;
    final items = await _local.getOutbox();
    if (items.isEmpty) return;

    for (final item in items) {
      final localId = item['local_id']?.toString() ?? '';
      final cid = item['conversation_id']?.toString() ?? '';
      final kind = (item['kind']?.toString() ?? 'text').toLowerCase();
      final body = item['body']?.toString() ?? '';
      if (localId.isEmpty || cid.isEmpty) {
        await _local.deleteOutboxMessage(localId);
        continue;
      }

      try {
        if (kind == 'image') {
          final raw = item['attachments_json']?.toString();
          final List<String> paths = raw == null || raw.isEmpty
              ? const []
              : (jsonDecode(raw) as List<dynamic>)
                  .map((e) => e.toString())
                  .where((e) => e.isNotEmpty)
                  .toList();
          final files = paths.map((p) => File(p)).where((f) => f.existsSync()).toList();
          if (files.isEmpty) {
            await _local.deleteOutboxMessage(localId);
            continue;
          }
          final sent = await _chat.sendImages(
            conversationId: cid,
            files: files,
            optionalText: body.isEmpty ? null : body,
            localSeq: _generateLocalSeq(),
            clientMsgId: localId,
          );
          if (sent.isNotEmpty) {
            await _local.deleteOutboxMessage(localId);
            final list = List<CM.ChatMessage>.from(
              _messagesByConv[cid] ?? const [],
            );
            list.removeWhere((m) => m.id == localId);
            for (final m in sent.reversed) {
              list.insert(0, m.copyWith(status: CM.ChatMessageStatus.sent));
            }
            _messagesByConv[cid] = list;
            _safeNotify();
            await _local.upsertMessages(sent);
          }
        } else {
          final real = await _chat.sendText(
            conversationId: cid,
            body: body,
            localSeq: _generateLocalSeq(),
            clientMsgId: localId,
          );
          await _local.deleteOutboxMessage(localId);
          final list = List<CM.ChatMessage>.from(
            _messagesByConv[cid] ?? const [],
          );
          final idx = list.indexWhere((m) => m.id == localId);
          if (idx != -1) {
            list[idx] = real.copyWith(status: CM.ChatMessageStatus.sent);
          } else {
            list.insert(0, real.copyWith(status: CM.ChatMessageStatus.sent));
          }
          _messagesByConv[cid] = list;
          _safeNotify();
          await _local.upsertMessages([real]);
        }
      } catch (_) {
        // اتركه لإعادة المحاولة لاحقًا
      }
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
    );

    final list = List<CM.ChatMessage>.from(
      _messagesByConv[conversationId] ?? const [],
    );
    list.insert(0, optimistic);
    _messagesByConv[conversationId] = list;
    _safeNotify();

    _applyOutgoingToConversationList(conversationId, body);

    await _local.upsertMessages([optimistic]);

    try {
      final real = await _chat.sendText(
        conversationId: conversationId,
        body: body,
        localSeq: _generateLocalSeq(),
        clientMsgId: optimistic.localId,
      );

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
      await _local.upsertMessages([
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
      _setError('تعذّر إرسال الرسالة: $e');
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
    unawaited(_local.upsertConversations([c]));
  }

  Future<void> sendImages({
    required String conversationId,
    required List<File> files,
    String? optionalText,
  }) async {
    if (_disposed) return;
    if (files.isEmpty &&
        (optionalText == null || optionalText.trim().isEmpty)) {
      return;
    }

    if ((optionalText ?? '').trim().isNotEmpty) {
      _applyOutgoingToConversationList(conversationId, optionalText!.trim());
    } else {
      _applyOutgoingToConversationList(conversationId, '📷 صورة');
    }

    final optimistic = CM.ChatMessage.optimisticImages(
      conversationId: conversationId,
      senderUid: currentUid,
      senderEmail: myEmail,
      files: files,
      caption: optionalText,
    );
    final list = List<CM.ChatMessage>.from(
      _messagesByConv[conversationId] ?? const [],
    );
    list.insert(0, optimistic);
    _messagesByConv[conversationId] = list;
    _safeNotify();
    await _local.upsertMessages([optimistic]);

    try {
      final sent = await _chat.sendImages(
        conversationId: conversationId,
        files: files,
        optionalText: optionalText,
        localSeq: _generateLocalSeq(),
        clientMsgId: optimistic.localId,
      );

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

        await _local.upsertMessages(sent);
        await _local.deleteMessage(optimistic.id);
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
          attachmentPaths: files.map((f) => f.path).toList(),
        );
      } catch (_) {}
      _setError('تعذّر إرسال الصور: $e');
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
          _setError('انتهت صلاحية تعديل هذه الرسالة.');
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
          await _local.upsertMessages([list[i]]);
        }
      }
      _scheduleConversationsRefresh();
    } catch (e) {
      _setError('تعذّر تعديل الرسالة: $e');
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
          _setError('انتهت صلاحية حذف هذه الرسالة.');
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
          await _local.upsertMessages([list[i]]);
        }
      }
      _scheduleConversationsRefresh();
    } catch (e) {
      _setError('تعذّر حذف الرسالة: $e');
      _safeNotify();
    }
  }

  // --------------------------------------------------------------------------
  // تعليم مقروئية
  // --------------------------------------------------------------------------
  Future<void> markConversationRead(String conversationId) async {
    DateTime? effective;
    try {
      effective = await _chat.markReadUpToLatest(conversationId);
    } catch (_) {}
    final ts = effective ?? DateTime.now().toUtc();
    _myLastReadByConv[conversationId] = ts;
    final i = _conversations.indexWhere((c) => c.id == conversationId);
    if (i != -1) {
      _conversations[i] = _conversations[i].copyWith(unreadCount: 0);
      _safeNotify();
      unawaited(_local.upsertConversations([_conversations[i]]));
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
            await _local.upsertMessages(toPersist);
          }
        } catch (_) {}
      }
    }

    // تحديث حالة القراءة محليًا (cursor)
    try {
      final states = _readStatesByConv[conversationId] ?? <CM.ChatReadState>[];
      final idx = states.indexWhere((s) => s.userUid == currentUid);
      final updatedState = CM.ChatReadState(
        conversationId: conversationId,
        userUid: currentUid,
        lastReadAt: ts,
        lastReadMessageId:
            list?.isNotEmpty == true ? list!.first.id : null,
        lastDeliveredAt: ts,
        lastDeliveredMessageId:
            list?.isNotEmpty == true ? list!.first.id : null,
      );
      if (idx == -1) {
        states.add(updatedState);
      } else {
        states[idx] = updatedState;
      }
      _readStatesByConv[conversationId] = states;
      await _local.upsertReadStates([updatedState]);
    } catch (_) {}
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
              (p.joinedAt == null ||
                  !p.joinedAt!.isAfter(message.createdAt)),
        )
        .map((p) => p.userUid)
        .toSet();
    if (targets.isEmpty) return CM.ChatMessageStatus.sent;

    final states = _readStatesByConv[conversationId] ?? const <CM.ChatReadState>[];
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
      final readOk =
          st.lastReadAt != null && !st.lastReadAt!.isBefore(msgTime);
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
        await _local.upsertMessages(list);
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
      final cached = await _local.getMessages(conversationId, limit: 500);
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
      _chat.pingTyping(conversationId, typing: isTyping);
    });
  }

  String displayForParticipant(String conversationId, String uid) {
    final parts =
        _participantsByConv[conversationId] ?? const <ChatParticipantLocal>[];
    for (final p in parts) {
      if (p.userUid == uid) {
        final nick = (p.nickname ?? '').trim();
        if (nick.isNotEmpty) return nick;
        final email = (p.email ?? '').trim();
        return email.isNotEmpty ? email : uid;
      }
    }
    return uid;
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
  Future<CM.ChatConversation> startDirectByEmail(String email) async {
    final conv = await _chat.startDMWithEmail(email);
    _ensureConversationVisible(
      conv,
      displayTitle: email.trim(),
    );
    _scheduleConversationsRefresh();
    return conv;
  }

  Future<CM.ChatConversation> createGroup({
    required String title,
    required List<String> memberEmails,
  }) async {
    final conv = await _chat.createGroup(
      title: title,
      memberEmails: memberEmails,
    );
    _ensureConversationVisible(
      conv,
      displayTitle: title.trim(),
    );
    _scheduleConversationsRefresh();
    return conv;
  }

  void _ensureConversationVisible(
    CM.ChatConversation conv, {
    String? displayTitle,
  }) {
    if (conv.id.isEmpty) return;
    final now = DateTime.now().toUtc();
    final normalized = conv.copyWith(
      lastMsgAt: conv.lastMsgAt ?? conv.updatedAt ?? now,
      updatedAt: conv.updatedAt ?? now,
    );
    final idx = _conversations.indexWhere((c) => c.id == conv.id);
    if (idx == -1) {
      _conversations.insert(0, normalized);
    } else {
      _conversations[idx] = normalized;
    }

    final trimmed = displayTitle?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      _displayTitleByConv[conv.id] = trimmed;
    }
    _safeNotify();
    unawaited(_local.upsertConversations([normalized]));
  }

  Future<void> groupSetTitle({
    required String conversationId,
    required String title,
  }) async {
    await _chat.groupSetTitle(conversationId: conversationId, title: title);
    _scheduleConversationsRefresh();
  }

  Future<void> groupSetFrozen({
    required String conversationId,
    required bool isFrozen,
    required bool adminsOnly,
  }) async {
    await _chat.groupSetFrozen(
      conversationId: conversationId,
      isFrozen: isFrozen,
      adminsOnly: adminsOnly,
    );
    _scheduleConversationsRefresh();
  }

  Future<void> groupSetMemberRole({
    required String conversationId,
    required String targetUid,
    required String role,
  }) async {
    await _chat.groupSetMemberRole(
      conversationId: conversationId,
      targetUid: targetUid,
      role: role,
    );
    _scheduleConversationsRefresh();
  }

  Future<void> groupRemoveMember({
    required String conversationId,
    required String targetUid,
  }) async {
    await _chat.groupRemoveMember(
      conversationId: conversationId,
      targetUid: targetUid,
    );
    _scheduleConversationsRefresh();
  }

  Future<void> groupDelete(String conversationId) async {
    await _chat.groupDelete(conversationId);
    _conversations.removeWhere((c) => c.id == conversationId);
    _safeNotify();
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
    int processed = 0;
    for (final m in msgs) {
      if (processed >= maxMessages) break;
      processed++;

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
        if (url == null || url.isEmpty) continue;
        try {
          await _attCache.ensureFileFor(url);
        } catch (_) {}
      }
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

  // --------------------------------------------------------------------------
  // ✅ تحويل الرسالة إلى محادثات/مجموعات أخرى
  // --------------------------------------------------------------------------
  Future<void> forwardMessage({
    required CM.ChatMessage message,
    required List<String> targetConversationIds,
  }) async {
    if (targetConversationIds.isEmpty) return;

    final originalText = (message.body ?? message.text).trim();
    final label =
        originalText.isNotEmpty ? 'تم تحويلها:\n$originalText' : 'تم تحويلها';

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
        _setError('تعذّر تحويل الرسالة: $e');
        _safeNotify();
      }
    }
  }

  // تنظيف
  @override
  void dispose() {
    _disposed = true;
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
      'role': role,
      'archived': archived,
      'pinned': pinned,
      'blocked': blocked,
      'is_deleted': isDeleted,
    };
  }
}
