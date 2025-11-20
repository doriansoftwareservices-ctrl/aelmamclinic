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
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/local/chat_local_store.dart';
import 'package:aelmamclinic/models/chat_invitation.dart';
import 'package:aelmamclinic/models/chat_models.dart' as CM;
import 'package:aelmamclinic/services/chat_service.dart';
import 'package:aelmamclinic/services/chat_realtime_notifier.dart';
import 'package:aelmamclinic/services/attachment_cache.dart';
import 'package:aelmamclinic/utils/logger.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider();

  // جداول
  static const String tableConversations = 'chat_conversations';
  static const String tableParticipants = 'chat_participants';
  static const String tableMessages = 'chat_messages';
  static const String tableAccountUsers = 'account_users';
  static const String tableProfiles = 'profiles';
  static const String tableReads = 'chat_reads';
  static const String tableAttachments = 'chat_attachments';
  static const String storageBucketChat = ChatService.attachmentsBucket;

  // نوافذ صلاحيات
  static const Duration editWindow = Duration(hours: 2);
  static const Duration deleteWindow = Duration(hours: 12);

  // تفضيل روابط موقعة
  final bool _preferSignedUrls = true;
  static const int _signedUrlTTL = 3600;

  // خدمات
  final SupabaseClient _sb = Supabase.instance.client;
  final ChatService _chat = ChatService.instance;
  final ChatRealtimeNotifier _rt = ChatRealtimeNotifier.instance;
  final AttachmentCache _attCache = AttachmentCache.instance; // ✅

  // هوية
  String get currentUid => _sb.auth.currentUser?.id ?? '';
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
  final Map<String, String> _aliasByUser = {};
  final Map<String, String> _displayTitleByConv = {};
  String displayTitleOf(String conversationId) =>
      _displayTitleByConv[conversationId] ?? 'محادثة';

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
  RealtimeChannel? _readsChannel;

  // RealtimeNotifier subs
  StreamSubscription<void>? _rtConvSub;
  StreamSubscription<void>? _rtPartSub;
  StreamSubscription<PostgresChangePayload>? _rtMsgSub;

  // Anti-dup / Throttling
  bool _listLoading = false;
  int _listRev = 0;
  Timer? _listDebounce;

  // حماية التخلص
  bool _disposed = false;
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  void _scheduleConversationsRefresh() {
    _listDebounce?.cancel();
    _listDebounce = Timer(const Duration(milliseconds: 250), () async {
      if (_disposed) return;
      await refreshConversations();
    });
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
      lastError = 'لا يوجد مستخدم مسجّل الدخول.';
      busy = false;
      _safeNotify();
      return;
    }
    busy = true;
    _safeNotify();
    try {
      final accId = accountId ?? await fetchAccountIdForCurrentUser();
      final accountFilter =
          (accId == null || accId.trim().isEmpty) ? null : accId.trim();

      if (accountFilter == null && !isSuperAdmin) {
        lastError = 'لا يمكن تحميل المحادثات لأن الحساب الحالي غير محدد.';
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
        lastError = 'تعذّرت تهيئة المحادثات، حاول مرة أخرى لاحقًا.';
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
          if (payload.eventType == PostgresChangeEvent.insert) {
            _handleMessageInsert(payload);
          }
        } catch (_) {}
        _scheduleConversationsRefresh();
      });

      ready = true;
    } catch (e, stackTrace) {
      debugPrint('ChatProvider.bootstrap: حدث خطأ غير متوقّع: $e');
      debugPrint('$stackTrace');
      lastError ??= 'حدث خطأ غير متوقع أثناء تجهيز المحادثات.';
    } finally {
      busy = false;
      _safeNotify();
    }
  }

  Future<String?> fetchAccountIdForCurrentUser() async {
    final uid = currentUid;
    if (uid.isEmpty) return null;

    try {
      final row = await _sb
          .from(tableProfiles)
          .select('account_id')
          .eq('id', uid)
          .maybeSingle();
      final acc = row?['account_id']?.toString();
      if (acc != null && acc.isNotEmpty) return acc;
    } catch (e, st) {
      _rpcWarn('profiles.account_id lookup failed', e, st);
    }

    try {
      final res = await _sb.rpc('my_account_id');
      final acc = (res ?? '').toString();
      if (acc.isNotEmpty && acc != 'null') return acc;
    } catch (e, st) {
      _rpcWarn('my_account_id RPC failed', e, st);
    }

    try {
      final row = await _sb
          .from(tableAccountUsers)
          .select('account_id')
          .eq('user_uid', uid)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final acc = row?['account_id']?.toString();
      if (acc != null && acc.isNotEmpty) return acc;
    } catch (e, st) {
      _rpcWarn('account_users account_id lookup failed', e, st);
    }

    _rpcWarn('account_id resolution returned null', StateError('no account binding for $uid'));
    return null;
  }

  // Helpers
  Future<void> _primeMyEmail() async {
    final e = (_sb.auth.currentUser?.email ?? '').toLowerCase();
    if (e.isNotEmpty) {
      _myEmailCache = e;
      return;
    }
    try {
      final row = await _sb
          .from(tableAccountUsers)
          .select('email')
          .eq('user_uid', currentUid)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final em = (row?['email']?.toString() ?? '').toLowerCase();
      if (em.isNotEmpty) {
        _myEmailCache = em;
        return;
      }
    } catch (_) {}
    _myEmailCache = 'unknown@local';
  }

  String get myEmail => _myEmailCache ?? 'unknown@local';

  Future<String> _signedOrPublicUrl(String bucket, String path) async {
    if (_preferSignedUrls) {
      try {
        final signed = await _sb.storage
            .from(bucket)
            .createSignedUrl(path, _signedUrlTTL);
        if (signed.trim().isNotEmpty) return signed;
      } catch (_) {}
    }
    return _sb.storage.from(bucket).getPublicUrl(path);
  }

  // ✅ دمج رابط HTTP مع مسار محلي إن وجد في الكاش (لا يفرض تنزيلًا هنا)
  Future<List<Map<String, dynamic>>> _normalizeAttachmentsToHttp(
    List<dynamic> rawList,
  ) async {
    final result = <Map<String, dynamic>>[];
    for (final e in rawList.whereType<Map<String, dynamic>>()) {
      final bucket = e['bucket']?.toString();
      final path = e['path']?.toString();
      final url = (bucket != null && path != null)
          ? await _signedOrPublicUrl(bucket, path)
          : (e['url']?.toString() ?? '');

      // تحقق من وجود نسخة محلية عبر "URL"
      String? localPath;
      if (url.isNotEmpty) {
        try {
          localPath = await _attCache.localPathIfAny(url);
        } catch (_) {}
      }

      // دمج extra موجود مسبقًا
      Map<String, dynamic> extra = {};
      final ex = e['extra'];
      if (ex is Map<String, dynamic>) extra = Map.of(ex);

      if (localPath != null) {
        extra['local_path'] = localPath;
      }

      result.add({
        'id': e['id']?.toString(),
        'type': e['type']?.toString() ?? 'image',
        'url': url,
        'bucket': bucket,
        'path': path,
        'mime_type': e['mime_type'] ?? e['mimeType'],
        'size_bytes': e['size_bytes'],
        'width': e['width'],
        'height': e['height'],
        'created_at': e['created_at'] ?? e['createdAt'],
        'extra': extra,
      });
    }
    return result;
  }

  Future<Map<String, dynamic>> _withHttpAttachments(
    Map<String, dynamic> msgRow,
  ) async {
    final att = msgRow['attachments'];
    if (att is List) {
      final normalized = await _normalizeAttachmentsToHttp(att);
      final copy = Map<String, dynamic>.from(msgRow);
      copy['attachments'] = normalized;
      return copy;
    }
    return msgRow;
  }

  // --------------------------------------------------------------------------
  // تحميل قائمة محادثاتي + المشاركين (+ آخر قراءة) مع دمج ذكي:
  // - يمنع وميض شارة unread (نأخذ max(prev, server) للمحادثات غير المفتوحة)
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
      // IDs لمحاوراتي
      final partRows = await _sb
          .from(tableParticipants)
          .select('conversation_id')
          .eq('user_uid', currentUid);

      final convIds = (partRows as List)
          .whereType<Map<String, dynamic>>()
          .map((r) => r['conversation_id']?.toString())
          .whereType<String>()
          .toSet()
          .toList();

      if (convIds.isEmpty) {
        if (myRev == _listRev) {
          _conversations..clear();
          _participantsByConv..clear();
          _displayTitleByConv..clear();
          _myLastReadByConv..clear();
          _safeNotify();
        }
        return;
      }

      // دفعات
      const chunk = 100;
      final fetched = <CM.ChatConversation>[];
      final tmpParticipantsByConv = <String, List<ChatParticipantLocal>>{};

      for (var i = 0; i < convIds.length; i += chunk) {
        final end = (i + chunk > convIds.length) ? convIds.length : i + chunk;
        final slice = convIds.sublist(i, end);

        final rows = await _sb
            .from(tableConversations)
            .select(
              'id, account_id, is_group, title, created_at, created_by, last_msg_at, last_msg_snippet',
            )
            .inFilter('id', slice);

        fetched.addAll(
          (rows as List).whereType<Map<String, dynamic>>().map(
            CM.ChatConversation.fromMap,
          ),
        );

        final partsRows = await _sb
            .from(tableParticipants)
            .select('conversation_id, user_uid, email, joined_at, nickname')
            .inFilter('conversation_id', slice);

        for (final r in (partsRows as List).whereType<Map<String, dynamic>>()) {
          final cid = r['conversation_id']?.toString();
          if (cid == null) continue;
          final p = ChatParticipantLocal.fromMap(r);
          (tmpParticipantsByConv[cid] ??= <ChatParticipantLocal>[]).add(p);
        }
      }

      // إزالة تكرار المحادثات
      final byId = <String, CM.ChatConversation>{};
      for (final c in fetched) {
        if (c.id.isNotEmpty) byId[c.id] = c;
      }
      final serverList = byId.values.toList();

      // عنونة العرض
      final aliasByUser = await _chat.fetchAliasMap();
      final tmpDisplay = <String, String>{};
      for (final c in serverList) {
        final cid = c.id.trim();
        if (cid.isEmpty) continue;

        if (c.isGroup) {
          tmpDisplay[cid] = (c.title?.trim().isNotEmpty == true)
              ? c.title!.trim()
              : 'مجموعة';
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

      // آخر قراءة لي
      final readsRows = await _sb
          .from(tableReads)
          .select('conversation_id,last_read_at')
          .eq('user_uid', currentUid)
          .inFilter('conversation_id', convIds);

      final lastReadByConv = <String, DateTime?>{};
      for (final r in (readsRows as List).whereType<Map<String, dynamic>>()) {
        final cid = (r['conversation_id'] ?? '').toString();
        final lr = DateTime.tryParse(
          (r['last_read_at'] ?? '').toString(),
        )?.toUtc();
        if (cid.isNotEmpty) lastReadByConv[cid] = lr;
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

        // unread تقدير سريع ثم max(prev, server) لغير المفتوح
        int serverUc = 0;
        final lr = lastReadByConv[srv.id];
        if (lr == null || effAt.isAfter(lr)) {
          serverUc = 1;
        }

        var uc = serverUc;
        if (openedId == srv.id) {
          uc = 0;
        } else if (prev != null) {
          uc = max(uc, prev.unreadCount ?? 0);
        }

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
      _displayTitleByConv
        ..clear()
        ..addAll(tmpDisplay);
      _myLastReadByConv
        ..clear()
        ..addAll(lastReadByConv);
      _conversations
        ..clear()
        ..addAll(merged);

      _safeNotify();
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

  Future<void> acceptGroupInvitation(String invitationId) async {
    if (invitationId.isEmpty) return;
    try {
      await _chat.acceptGroupInvitation(invitationId);
      await refreshConversations();
    } on ChatInvitationException catch (e) {
      _rpcWarn('chat_accept_invitation failed', e);
      lastError = e.message;
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
      lastError = e.message;
      _safeNotify();
      rethrow;
    }
  }

  void _rpcWarn(String label, Object error, [StackTrace? st]) {
    log.w('Chat RPC warning: $label -> $error', tag: 'CHAT_RPC', st: st);
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
  }

  String _trimSnippet(String s) {
    final t = s.trim();
    return t.length > 80 ? '${t.substring(0, 80)}…' : t;
  }

  // --------------------------------------------------------------------------
  // فتح/إغلاق محادثة
  // --------------------------------------------------------------------------
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
    _olderCursorByConv[conversationId] = cached.isNotEmpty
        ? cached.last.createdAt
        : null;
    _safeNotify();

    // ✅ حمّل دفعة حديثة
    await loadMoreMessages(conversationId);
    if (_disposed) return;

    // ✅ Prefetch للرسائل الظاهرة (صور فقط غالبًا)
    unawaited(prefetchVisibleAttachments(conversationId, maxMessages: 30));

    try {
      await _roomMsgsSub?.cancel();
    } catch (_) {}
    _roomMsgsSub = _chat
        .watchMessages(conversationId)
        .listen(
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
            lastError = 'Realtime error: $e';
            _safeNotify();
          },
        );

    try {
      await _typingSub?.cancel();
    } catch (_) {}
    _typingSub = _chat.typingStream(conversationId).listen((payload) {
      if (_disposed) return;
      final String convId = (payload['conversation_id'] ?? '').toString();
      final String? uid = payload['uid']?.toString();
      final bool typing = payload['typing'] == true;

      if (convId.isEmpty ||
          convId != conversationId ||
          uid == null ||
          uid == currentUid) {
        return;
      }
      final set = (_typingUidsByConv[convId] ??= <String>{});
      if (typing) {
        set.add(uid);
      } else {
        set.remove(uid);
      }
      _safeNotify();
    });

    try {
      _readsChannel?.unsubscribe();
    } catch (_) {}
    _readsChannel = _sb
        .channel('chat:reads:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: tableReads,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (_) => _applyReadsToOutgoing(conversationId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: tableReads,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (_) => _applyReadsToOutgoing(conversationId),
        )
        .subscribe();

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
      _readsChannel?.unsubscribe();
    } catch (_) {}
    try {
      if (_readsChannel != null) {
        _sb.removeChannel(_readsChannel!);
      }
    } catch (_) {}
    _readsChannel = null;

    try {
      _listDebounce?.cancel();
    } catch (_) {}
    _typingPingDebounce?.cancel();
  }

  // --------------------------------------------------------------------------
  // جلب دفعات رسائل
  // --------------------------------------------------------------------------
  Future<List<CM.ChatMessage>> _fetchRecentBatchFromSupabase({
    required String conversationId,
    int limit = 40,
    DateTime? before,
  }) async {
    final query = _sb
        .from(tableMessages)
        .select('''
          id, conversation_id, sender_uid, sender_email, kind,
          body, text, edited, deleted, created_at, edited_at, deleted_at,
          reply_to_message_id, reply_to_snippet, mentions,
          attachments:$tableAttachments (
            id, message_id, bucket, path, mime_type, size_bytes, width, height, created_at
          )
        ''')
        .eq('conversation_id', conversationId)
        .or('deleted.is.false,deleted.is.null');

    if (before != null) {
      query.lt('created_at', before.toUtc().toIso8601String());
    }

    final rows = await query.order('created_at', ascending: false).limit(limit);

    final list = <CM.ChatMessage>[];
    for (final r in (rows as List).whereType<Map<String, dynamic>>()) {
      final normalized = await _withHttpAttachments(r);
      list.add(CM.ChatMessage.fromMap(normalized, currentUid: currentUid));
    }
    return list;
  }

  // --------------------------------------------------------------------------
  // تحميل المزيد
  // --------------------------------------------------------------------------
  Future<void> loadMoreMessages(String conversationId) async {
    try {
      final DateTime? before = _olderCursorByConv[conversationId];

      final listDesc = await _fetchRecentBatchFromSupabase(
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
        lastError = 'تعذّر تحميل الرسائل: $e';
        _safeNotify();
      }
    }
  }

  // --------------------------------------------------------------------------
  // إرسال نص/صور
  // --------------------------------------------------------------------------
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
      lastError = 'تعذّر إرسال الرسالة: $e';
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

    try {
      final sent = await _chat.sendImages(
        conversationId: conversationId,
        files: files,
        optionalText: optionalText,
        localSeq: _generateLocalSeq(),
      );

      if (sent.isNotEmpty) {
        final list = List<CM.ChatMessage>.from(
          _messagesByConv[conversationId] ?? const [],
        );
        final existingIds = list.map((m) => m.id).toSet();

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
      }

      _scheduleConversationsRefresh();
      await _applyReadsToOutgoing(conversationId);
    } on ChatAttachmentUploadException catch (e) {
      lastError = e.message;
      _safeNotify();
      rethrow;
    } catch (e) {
      lastError = 'تعذّر إرسال الصور: $e';
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
          lastError = 'انتهت صلاحية تعديل هذه الرسالة.';
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
      lastError = 'تعذّر تعديل الرسالة: $e';
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
          lastError = 'انتهت صلاحية حذف هذه الرسالة.';
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
      lastError = 'تعذّر حذف الرسالة: $e';
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
  }

  // تطبيق قراءة الآخرين على رسائلي
  Future<void> _applyReadsToOutgoing(String conversationId) async {
    try {
      final rows = await _sb
          .from(tableReads)
          .select('user_uid,last_read_at')
          .eq('conversation_id', conversationId);

      final othersReadTimes = (rows as List)
          .whereType<Map<String, dynamic>>()
          .where((r) => r['user_uid']?.toString() != currentUid)
          .map((r) => DateTime.tryParse((r['last_read_at'] ?? '').toString()))
          .whereType<DateTime>()
          .map((d) => d.toUtc())
          .toList();

      if (othersReadTimes.isEmpty) return;

      final latestRead = othersReadTimes.reduce((a, b) => a.isAfter(b) ? a : b);

      final list = List<CM.ChatMessage>.from(
        _messagesByConv[conversationId] ?? const [],
      );
      var changed = false;

      for (var i = 0; i < list.length; i++) {
        final m = list[i];
        final isReadOrEarlier = !m.createdAt.isAfter(latestRead);
        if (m.senderUid == currentUid &&
            isReadOrEarlier &&
            m.status != CM.ChatMessageStatus.read) {
          list[i] = m.copyWith(status: CM.ChatMessageStatus.read);
          changed = true;
        }
      }

      if (changed) {
        _messagesByConv[conversationId] = list;
        _safeNotify();
        try {
          final updated = list
              .where(
                (m) =>
                    m.senderUid == currentUid &&
                    m.status == CM.ChatMessageStatus.read,
              )
              .toList();
          if (updated.isNotEmpty) {
            await _local.upsertMessages(updated);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  // --------------------------------------------------------------------------
  // بحث داخل المحادثة
  // --------------------------------------------------------------------------
  String _escapeIlike(String q) {
    return q
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }

  Future<List<CM.ChatMessage>> searchInConversation({
    required String conversationId,
    required String query,
    int limit = 100,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const <CM.ChatMessage>[];

    try {
      final esc = _escapeIlike(q);
      final rows = await _sb
          .from(tableMessages)
          .select()
          .eq('conversation_id', conversationId)
          .or('deleted.is.false,deleted.is.null')
          .or('body.ilike.%$esc%,text.ilike.%$esc%')
          .order('created_at', ascending: false)
          .limit(limit);

      final list = (rows as List)
          .whereType<Map<String, dynamic>>()
          .map(
            (row) => CM.ChatMessage.fromMap(
              row as Map<String, dynamic>,
              currentUid: currentUid,
            ),
          )
          .toList();

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

  List<String> displayNamesForTyping(
    String conversationId,
    Iterable<String> uids,
  ) {
    return [for (final u in uids) displayForParticipant(conversationId, u)];
  }

  // إنشاء DM / مجموعة
  Future<CM.ChatConversation> startDirectByEmail(String email) async {
    final conv = await _chat.startDMWithEmail(email);
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
    _scheduleConversationsRefresh();
    return conv;
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

    final path = 'attachments/$conversationId/$messageId/$name';

    await _sb.storage
        .from(storageBucketChat)
        .upload(
          path,
          file,
          fileOptions: FileOptions(upsert: false, contentType: mime),
        );

    final url = await _signedOrPublicUrl(storageBucketChat, path);
    return (url, path);
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

    final path = 'attachments/$conversationId/legacy/$rnd/$name';

    await _sb.storage
        .from(storageBucketChat)
        .upload(
          path,
          file,
          fileOptions: FileOptions(upsert: false, contentType: mime),
        );

    final url = await _signedOrPublicUrl(storageBucketChat, path);
    return (url, path);
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
    final label = originalText.isNotEmpty
        ? 'تم تحويلها:\n$originalText'
        : 'تم تحويلها';

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
        lastError = 'تعذّر تحويل الرسالة: $e';
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
      _readsChannel?.unsubscribe();
    } catch (_) {}
    try {
      if (_readsChannel != null) {
        _sb.removeChannel(_readsChannel!);
      }
    } catch (_) {}
    _readsChannel = null;

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

  const ChatParticipantLocal({
    required this.conversationId,
    required this.userUid,
    this.email,
    this.joinedAt,
    this.nickname,
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

    return ChatParticipantLocal(
      conversationId: m['conversation_id']?.toString() ?? '',
      userUid: m['user_uid']?.toString() ?? '',
      email: m['email']?.toString(),
      joinedAt: _parse(m['joined_at']),
      nickname: m['nickname']?.toString(),
    );
  }

  factory ChatParticipantLocal.fallback(String conversationId) =>
      ChatParticipantLocal(
        conversationId: conversationId,
        userUid: '',
        email: null,
      );
}
