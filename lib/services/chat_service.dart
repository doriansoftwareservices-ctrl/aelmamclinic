// lib/services/chat_service.dart
//
// ChatService — طبقة خدمة شاملة لميزة الدردشة فوق Supabase.
//
// هذه النسخة تتضمن:
// - ✅ منع التكرار عبر upsert(device_id,local_id) + ضمان توليد local_id دائمًا
// - ✅ الإبقاء على or('deleted.is.false,deleted.is.null') في الجلب العادي
// - ✅ تمرير account_id الصحيح من المحادثة عند إرسال الرسائل
// - ✅ عدم استخدام RETURNING عند إنشاء المحادثة
// - ✅ تعيين وقت القراءة على created_at لآخر رسالة
// - ✅ تهريب نص البحث قبل ilike
// - ✅ upsert للمشاركين على (conversation_id,user_uid) بدل insert
// - ✅ تضمين المحادثات التي أنشأتها أنت حتى لو لم تُدرَج كمشارك (اتحاد participants + created_by)
// - ✅ تفضيل توقيع الروابط عبر Edge Function (sign-attachment) ثم fallback إلى createSignedUrl
// - ✅ استخدام اسم الـ bucket المركزي من AppConstants.chatBucketName
// - ✅ استخدام بنية مسار المرفقات: attachments/<conversationId>/<messageId>/<fileName>
// - ✅ تسمية علاقة embed للمرفقات لتفادي التباس العلاقات في PostgREST

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:postgrest/postgrest.dart' show PostgrestException;

import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/models/chat_invitation.dart';
import 'package:aelmamclinic/models/chat_models.dart'
    show
        ChatAttachment,
        ChatConversation,
        ChatMessage,
        ChatMessageKind,
        ChatMessageKindX,
        ChatMessageStatus,
        ConversationListItem;
import 'package:aelmamclinic/models/chat_reaction.dart';
import 'package:aelmamclinic/utils/device_id.dart';
import 'package:aelmamclinic/utils/local_seq.dart';

class ChatAttachmentUploadException implements Exception {
  final String message;
  final Object? cause;
  ChatAttachmentUploadException(this.message, {this.cause});
  @override
  String toString() => message;
}

class ChatInvitationException implements Exception {
  final String message;
  ChatInvitationException(this.message);
  @override
  String toString() => message;
}

class ChatService {
  ChatService._();
  static final ChatService instance = ChatService._();

  final SupabaseClient _sb = Supabase.instance.client;

  // --------------------------------------------------------------
  // ثوابت
  // --------------------------------------------------------------
  static const String attachmentsBucket = AppConstants.chatBucketName;
  final bool _preferSignedUrls = !AppConstants.chatPreferPublicUrls;
  static const int _signedUrlTTL =
      AppConstants.storageSignedUrlTTLSeconds; // 1 ساعة افتراضيًا

  static const _tblConvs = 'chat_conversations';
  static const _tblParts = 'chat_participants';
  static const _tblMsgs = 'chat_messages';
  static const _tblReads = 'chat_reads';
  static const _tblAccUsers = 'account_users';
  static const _tblAtts = 'chat_attachments';
  static const _tblReacts = 'chat_reactions';

  // اسم علاقة FK المرغوبة بين chat_messages و chat_attachments
  static const _relAttsByMsg = 'chat_attachments_message_id_fkey';

  // --------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------
  User? get currentUser => _sb.auth.currentUser;

  // uuid v4 محلي لتفادي RETURNING عند إنشاء المحادثة
  String _uuidV4() {
    final r = math.Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
    String h(int x) => x.toRadixString(16).padLeft(2, '0');
    final hex = b.map(h).join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  Map<String, dynamic>? _asJsonMap(dynamic value) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, dynamic val) => MapEntry(key.toString(), val));
    }
    return null;
  }

  Future<void> _uploadToStorage({
    required String path,
    required File file,
    required FileOptions options,
  }) async {
    try {
      await _sb.storage
          .from(attachmentsBucket)
          .upload(path, file, fileOptions: options);
    } on StorageException catch (e) {
      final message = (e.statusCode == 403)
          ? 'لا تملك صلاحية رفع المرفقات لهذه المحادثة.'
          : (e.message ?? 'فشل رفع المرفقات.');
      throw ChatAttachmentUploadException(message, cause: e);
    } catch (e) {
      throw ChatAttachmentUploadException('فشل رفع المرفقات: $e', cause: e);
    }
  }

  void _ensureInvitationRpcOk(dynamic response, String fallback) {
    if (response is Map && response['ok'] == true) {
      return;
    }
    final error = response is Map ? response['error']?.toString() : null;
    throw ChatInvitationException(
      error == null || error.isEmpty ? fallback : error,
    );
  }

  Future<({String? accountId, String? role, String? email, String? deviceId})>
  _myAccountRow() async {
    final u = _sb.auth.currentUser;
    if (u == null) {
      return (accountId: null, role: null, email: null, deviceId: null);
    }
    try {
      final raw = await _sb
          .from(_tblAccUsers)
          .select('account_id, role, email, device_id')
          .eq('user_uid', u.id)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final row = _asJsonMap(raw);
      return (
        accountId: row?['account_id']?.toString(),
        role: row?['role']?.toString(),
        email: (row?['email']?.toString() ?? '').toLowerCase(),
        deviceId: row?['device_id']?.toString(),
      );
    } catch (_) {
      return (accountId: null, role: null, email: null, deviceId: null);
    }
  }

  /// account_id الخاص بالمحادثة (مفضل للرسائل ليتوافق مع RLS)
  Future<String?> _conversationAccountId(String conversationId) async {
    try {
      final raw = await _sb
          .from(_tblConvs)
          .select('account_id')
          .eq('id', conversationId)
          .maybeSingle();
      final row = _asJsonMap(raw);
      final v = row?['account_id']?.toString();
      if (v == null || v.isEmpty || v == 'null') return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// يضمن لنا تحديد بريد المرسل.
  String? _bestSenderEmail(String? meEmail) {
    final authEmail = _sb.auth.currentUser?.email;
    final e = (meEmail?.trim().isNotEmpty == true ? meEmail : authEmail)
        ?.toLowerCase();
    return (e != null && e.isNotEmpty) ? e : null;
  }

  /// يحدد device_id: إن لم يجده في account_users يستخدم DeviceId.get() محليًا.
  Future<String> _determineDeviceId(String? fromAccountUsers) async {
    if (fromAccountUsers != null && fromAccountUsers.trim().isNotEmpty) {
      return fromAccountUsers;
    }
    return await DeviceId.get();
  }

  /// ✅ next local_id
  Future<int?> _nextSeqForMe() async {
    try {
      final me = await _myAccountRow();
      final dev = (me.deviceId ?? '').trim();
      if (dev.isNotEmpty) {
        return await LocalSeq.instance.nextForTriplet(
          deviceId: dev,
          accountId: me.accountId,
        );
      }
      return await LocalSeq.instance.nextGlobal();
    } catch (_) {
      return null;
    }
  }

  Future<String> _signedOrPublicUrl(String bucket, String path) async {
    if (_preferSignedUrls) {
      // 1) جرّب Edge Function (sign-attachment)
      try {
        final res = await _sb.functions.invoke(
          'sign-attachment',
          body: {'bucket': bucket, 'path': path, 'expiresIn': _signedUrlTTL},
        );
        final data = res.data;
        if (data is Map) {
          final s = (data['signedUrl'] ?? data['url'])?.toString();
          if (s != null && s.trim().isNotEmpty) return s;
        }
      } catch (_) {}
      // 2) fallback: createSignedUrl من Storage
      try {
        final s = await _sb.storage
            .from(bucket)
            .createSignedUrl(path, _signedUrlTTL);
        if (s.trim().isNotEmpty) return s;
      } catch (_) {}
    }
    // 3) أخيرًا: publicUrl
    return _sb.storage.from(bucket).getPublicUrl(path);
  }

  String _safeFileName(String name) {
    final s = name.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_\.\-]'), '_');
    return s.isEmpty ? 'file_${DateTime.now().millisecondsSinceEpoch}' : s;
  }

  String _friendlyFileName(File file, {String fallback = 'file'}) {
    try {
      final uriName = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : null;
      final pathName = p.basename(file.path);
      final candidate = (uriName ?? pathName).trim();
      return _safeFileName(candidate.isEmpty ? fallback : candidate);
    } catch (_) {
      return _safeFileName(fallback);
    }
  }

  String _guessMime(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'application/octet-stream';
  }

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
        'extra': e['extra'],
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

  /// إدراج عام مع سقوط اختياري — **لا تُستخدم للرسائل بعد الآن**.
  Future<Map<String, dynamic>> _insertWithFallback(
    String table,
    Map<String, dynamic> map, {
    List<String> fallbackKeys = const [
      'account_id',
      'mentions',
      'reply_to_message_id',
      'reply_to_snippet',
      'attachments',
    ],
  }) async {
    try {
      return await _sb.from(table).insert(map).select().single();
    } catch (_) {
      final alt = Map<String, dynamic>.from(map);
      for (final k in fallbackKeys) {
        alt.remove(k);
      }
      return await _sb.from(table).insert(alt).select().single();
    }
  }

  String _buildSnippet({required ChatMessageKind kind, String? body}) {
    if (kind == ChatMessageKind.text) {
      final s = (body ?? '').trim();
      if (s.isEmpty) return 'رسالة';
      return s.length > 64 ? '${s.substring(0, 64)}…' : s;
    }
    if (kind == ChatMessageKind.image) return '📷 صورة';
    return 'رسالة';
  }

  Future<void> _updateConversationLastSummary({
    required String conversationId,
    required DateTime lastAt,
    required String snippet,
  }) async {
    try {
      await _sb
          .from(_tblConvs)
          .update({
            'last_msg_at': lastAt.toUtc().toIso8601String(),
            'last_msg_snippet': snippet,
          })
          .eq('id', conversationId);
    } catch (_) {}
  }

  Future<void> refreshConversationLastSummary(String conversationId) async {
    try {
      final raw = await _sb
          .from(_tblMsgs)
          .select('kind, body, created_at, deleted')
          .eq('conversation_id', conversationId)
          .or('deleted.is.false,deleted.is.null')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final last = _asJsonMap(raw);

      if (last == null) {
        await _sb
            .from(_tblConvs)
            .update({'last_msg_at': null, 'last_msg_snippet': null})
            .eq('id', conversationId);
        return;
      }

      final kindStr = last['kind']?.toString() ?? ChatMessageKind.text.dbValue;
      final kind = ChatMessageKindX.fromDb(kindStr);
      final snippet = _buildSnippet(kind: kind, body: last['body']?.toString());
      final lastAt = DateTime.parse(last['created_at'].toString()).toUtc();

      await _updateConversationLastSummary(
        conversationId: conversationId,
        lastAt: lastAt,
        snippet: snippet,
      );
    } catch (_) {}
  }

  // --------------------------------------------------------------
  // محادثات
  // --------------------------------------------------------------
  Future<ChatConversation?> findExistingDMByUids({
    required String uidA,
    required String uidB,
  }) async {
    // ملاحظة: حدّد اسم علاقة الـ FK صراحةً لتفادي التباس PostgREST.
    final rows = await _sb
        .from(_tblParts)
        .select('''
    conversation_id,
    conversation:${_tblConvs}!fk_chat_participants_conversation(
      id, is_group, account_id, title, created_at, created_by, last_msg_at, last_msg_snippet
    )
  ''')
        .inFilter('user_uid', [uidA, uidB]);

    final countByConv = <String, int>{};
    final mapConv = <String, Map<String, dynamic>>{};
    for (final r in (rows as List).whereType<Map<String, dynamic>>()) {
      final cid = (r['conversation_id'] ?? '').toString();
      if (cid.isEmpty) continue;
      countByConv[cid] = (countByConv[cid] ?? 0) + 1;
      final conv = r['conversation'];
      if (conv is Map<String, dynamic>) {
        mapConv[cid] = conv;
      }
    }

    for (final e in countByConv.entries) {
      final cid = e.key;
      final cMap = mapConv[cid] ?? const {};
      if (e.value >= 2 && (cMap['is_group'] == false)) {
        return ChatConversation.fromMap(cMap);
      }
    }
    return null;
  }

  Future<ChatConversation> startDMWithEmail(String email) async {
    final u = _sb.auth.currentUser;
    if (u == null) {
      throw 'لا يوجد مستخدم مسجّل الدخول.';
    }
    final me = await _myAccountRow();
    final myRole = (me.role?.toLowerCase() ?? '');
    final myAcc = (me.accountId ?? '').trim();

    final targetRowRaw = await _sb
        .from(_tblAccUsers)
        .select('user_uid, email, account_id, role')
        .ilike('email', email.toLowerCase())
        .maybeSingle();

    if (targetRowRaw == null) {
      throw 'لا يوجد مستخدم بالبريد: $email';
    }

    final Map<String, dynamic> targetRow = targetRowRaw is Map<String, dynamic>
        ? targetRowRaw
        : Map<String, dynamic>.from(targetRowRaw as Map);

    final otherUid = targetRow['user_uid']?.toString() ?? '';
    if (otherUid.isEmpty) {
      throw 'حدث خلل أثناء جلب المستخدم الهدف.';
    }

    final otherEmail = (targetRow['email']?.toString() ?? email).toLowerCase();

    final targetRole = (targetRow['role']?.toString() ?? '').toLowerCase();
    if (targetRole == 'superadmin' && myRole != 'superadmin') {
      throw 'غير مسموح للموظفين مراسلة السوبر أدمن مباشرة.';
    }
    if (otherUid == u.id) throw 'لا يمكنك مراسلة نفسك.';

    final existing = await findExistingDMByUids(uidA: u.id, uidB: otherUid);
    if (existing != null) return existing;

    String? convAccountId;
    final otherAcc = (targetRow['account_id']?.toString() ?? '').trim();
    if (otherAcc.isNotEmpty && myAcc.isNotEmpty && otherAcc == myAcc) {
      convAccountId = myAcc;
    }
    final convId = _uuidV4();
    final nowIso = DateTime.now().toUtc().toIso8601String();

    await _sb.from(_tblConvs).insert({
      'id': convId,
      'account_id': convAccountId,
      'is_group': false,
      'title': null,
      'created_by': u.id,
      'created_at': nowIso,
      'updated_at': nowIso,
    });

    // ✅ upsert للمشاركين
    await _sb.from(_tblParts).upsert([
      {
        'conversation_id': convId,
        'user_uid': u.id,
        'email': (_bestSenderEmail(me.email) ?? '').toLowerCase(),
        'joined_at': nowIso,
      },
      {
        'conversation_id': convId,
        'user_uid': otherUid,
        'email': otherEmail,
        'joined_at': nowIso,
      },
    ], onConflict: 'conversation_id,user_uid');

    final row = await _sb
        .from(_tblConvs)
        .select(
          'id, is_group, title, account_id, created_by, created_at, updated_at, last_msg_at, last_msg_snippet',
        )
        .eq('id', convId)
        .maybeSingle();

    if (row != null) {
      return ChatConversation.fromMap(row);
    }

    return ChatConversation.fromMap({
      'id': convId,
      'is_group': false,
      'title': null,
      'account_id': convAccountId,
      'created_by': u.id,
      'created_at': nowIso,
      'updated_at': nowIso,
      'last_msg_at': null,
      'last_msg_snippet': null,
    });
  }

  Future<ChatConversation> createGroup({
    required String title,
    required List<String> memberEmails,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null) throw 'لا يوجد مستخدم مسجّل الدخول.';
    if (title.trim().isEmpty) throw 'اكتب اسم المجموعة.';
    if (memberEmails.isEmpty) throw 'أضِف عضوًا واحدًا على الأقل.';

    final me = await _myAccountRow();
    final myAcc = (me.accountId ?? '').trim();
    if (myAcc.isEmpty) throw 'تعذّر تحديد الحساب الحالي.';

    final members = <({String uid, String email, String accountId})>[];
    for (final e in memberEmails) {
      final row = await _sb
          .from(_tblAccUsers)
          .select('user_uid, email, account_id')
          .ilike('email', e.toLowerCase())
          .maybeSingle();
      if (row == null) throw 'لا يوجد مستخدم بالبريد: $e';
      final uid = row['user_uid'].toString();
      if (uid == u.id) continue;
      if (!members.any((m) => m.uid == uid)) {
        members.add((
          uid: uid,
          email: (row['email']?.toString() ?? e).toLowerCase(),
          accountId: (row['account_id']?.toString() ?? '').trim(),
        ));
      }
    }

    final convId = _uuidV4();
    final nowIso = DateTime.now().toUtc().toIso8601String();

    await _sb.from(_tblConvs).insert({
      'id': convId,
      'account_id': myAcc,
      'is_group': true,
      'title': title.trim(),
      'created_by': u.id,
      'created_at': nowIso,
      'updated_at': nowIso,
    });

    final participantRows = <Map<String, dynamic>>[
      {
        'conversation_id': convId,
        'user_uid': u.id,
        'email': (_bestSenderEmail(me.email) ?? '').toLowerCase(),
        'joined_at': nowIso,
      },
    ];
    await _sb
        .from(_tblParts)
        .upsert(participantRows, onConflict: 'conversation_id,user_uid');
    if (members.isNotEmpty) {
      final invites = members
          .map(
            (m) => {
              'conversation_id': convId,
              'inviter_uid': u.id,
              'invitee_uid': m.uid,
              'invitee_email': m.email,
              'created_at': nowIso,
            },
          )
          .toList();
      await _sb
          .from('chat_group_invitations')
          .upsert(invites, onConflict: 'conversation_id,invitee_uid');
    }

    return ChatConversation.fromMap({
      'id': convId,
      'account_id': myAcc,
      'is_group': true,
      'title': title.trim(),
      'created_by': u.id,
      'created_at': nowIso,
      'updated_at': nowIso,
      'last_msg_at': null,
      'last_msg_snippet': null,
    });
  }

  Future<List<ConversationListItem>> fetchMyConversationsOverview() async {
    final u = _sb.auth.currentUser;
    if (u == null) return const <ConversationListItem>[];

    // (1) محادثات أنا مشارك فيها
    final myPartRows = await _sb
        .from(_tblParts)
        .select('conversation_id')
        .eq('user_uid', u.id);

    final partConvIds = (myPartRows as List)
        .whereType<Map<String, dynamic>>()
        .map((e) => e['conversation_id'].toString())
        .toSet();

    // (2) + محادثات أنا منشئها، حتى لو لم أُدرج كمشارك
    final createdRows = await _sb
        .from(_tblConvs)
        .select('id')
        .eq('created_by', u.id);
    final createdConvIds = (createdRows as List)
        .whereType<Map<String, dynamic>>()
        .map((e) => e['id'].toString())
        .toSet();

    final convIds = {...partConvIds, ...createdConvIds}.toList();
    if (convIds.isEmpty) return const <ConversationListItem>[];

    final convRows = await _sb
        .from(_tblConvs)
        .select(
          'id, is_group, title, account_id, created_by, created_at, updated_at, last_msg_at, last_msg_snippet',
        )
        .inFilter('id', convIds)
        .order('last_msg_at', ascending: false);

    final conversations = (convRows as List)
        .whereType<Map<String, dynamic>>()
        .map(ChatConversation.fromMap)
        .toList();

    final allPartsRows = await _sb
        .from(_tblParts)
        .select('conversation_id, user_uid, email')
        .inFilter('conversation_id', convIds);

    final byConv = <String, List<_ChatParticipant>>{};
    for (final r in (allPartsRows as List).whereType<Map<String, dynamic>>()) {
      final cid = r['conversation_id']?.toString() ?? '';
      (byConv[cid] ??= []).add(_ChatParticipant.fromMap(r));
    }

    final readsRows = await _sb
        .from(_tblReads)
        .select('conversation_id, last_read_at')
        .eq('user_uid', u.id)
        .inFilter('conversation_id', convIds);

    final lastReadAtByConv = <String, DateTime?>{};
    for (final r in (readsRows as List).whereType<Map<String, dynamic>>()) {
      final cid = r['conversation_id'].toString();
      final ts = r['last_read_at'];
      lastReadAtByConv[cid] = ts == null
          ? null
          : DateTime.tryParse(ts.toString())?.toUtc();
    }

    final items = <ConversationListItem>[];
    for (final c in conversations) {
      final parts = byConv[c.id] ?? const <_ChatParticipant>[];
      final emails = parts
          .map((p) => p.email ?? '')
          .where((e) => e.trim().isNotEmpty)
          .map((e) => e.toLowerCase())
          .toSet()
          .toList();

      String title = (c.isGroup)
          ? (c.title?.trim().isNotEmpty == true
                ? c.title!.trim()
                : emails
                      .where((e) => e != (u.email ?? '').toLowerCase())
                      .take(3)
                      .join('، '))
          : (emails.firstWhere(
              (e) => e != (u.email ?? '').toLowerCase(),
              orElse: () => emails.isNotEmpty ? emails.first : 'محادثة',
            ));

      final lastMsgAt = c.lastMsgAt;
      final lastReadAt = lastReadAtByConv[c.id];
      final hasUnread =
          (lastMsgAt != null &&
          (lastReadAt == null || lastMsgAt.isAfter(lastReadAt)));

      final convForList = c.copyWith(unreadCount: hasUnread ? 1 : 0);

      items.add(
        ConversationListItem(
          conversation: convForList,
          displayTitle: title.isEmpty ? 'محادثة' : title,
        ),
      );
    }

    return items;
  }

  // --------------------------------------------------------------
  // رسائل
  // --------------------------------------------------------------
  Future<List<ChatMessage>> fetchMessages({
    required String conversationId,
    int limit = 40,
  }) async {
    try {
      final data = await _sb
          .from(_tblMsgs)
          .select('''
        id, conversation_id, sender_uid, sender_email, kind,
        body, text, edited, deleted, created_at, edited_at, deleted_at,
        reply_to_message_id, reply_to_snippet, mentions,
        attachments:${_tblAtts}!$_relAttsByMsg (
          id, message_id, bucket, path, mime_type, size_bytes, width, height, created_at
        ),
        delivery_receipts:chat_delivery_receipts (
          user_uid, delivered_at
        )
      ''')
          .eq('conversation_id', conversationId)
          .or('deleted.is.false,deleted.is.null')
          .order('created_at', ascending: true)
          .limit(limit);

      final list = <ChatMessage>[];
      for (final row in (data as List).whereType<Map<String, dynamic>>()) {
        final normalized = await _withHttpAttachments(row);
        list.add(
          ChatMessage.fromMap(normalized, currentUid: _sb.auth.currentUser?.id),
        );
      }
      unawaited(_markDeliveredFor(list));
      return list;
    } catch (_) {
      final data = await _sb
          .from(_tblMsgs)
          .select(
            'id, conversation_id, sender_uid, sender_email, kind, body, text, edited, deleted, created_at, edited_at, deleted_at, reply_to_message_id, reply_to_snippet, mentions, attachments, delivery_receipts:chat_delivery_receipts(user_uid, delivered_at)',
          )
          .eq('conversation_id', conversationId)
          .or('deleted.is.false,deleted.is.null')
          .order('created_at', ascending: true)
          .limit(limit);

      final list = <ChatMessage>[];
      for (final row in (data as List).whereType<Map<String, dynamic>>()) {
        final normalized = await _withHttpAttachments(row);
        list.add(
          ChatMessage.fromMap(normalized, currentUid: _sb.auth.currentUser?.id),
        );
      }
      unawaited(_markDeliveredFor(list));
      return list;
    }
  }

  Future<List<ChatMessage>> fetchOlderMessages({
    required String conversationId,
    required DateTime beforeCreatedAt,
    int limit = 40,
  }) async {
    try {
      final data = await _sb
          .from(_tblMsgs)
          .select('''
        id, conversation_id, sender_uid, sender_email, kind,
        body, text, edited, deleted, created_at, edited_at, deleted_at,
        reply_to_message_id, reply_to_snippet, mentions,
        attachments:${_tblAtts}!$_relAttsByMsg (
          id, message_id, bucket, path, mime_type, size_bytes, width, height, created_at
        )
      ''')
          .eq('conversation_id', conversationId)
          .or('deleted.is.false,deleted.is.null')
          .lt('created_at', beforeCreatedAt.toUtc().toIso8601String())
          .order('created_at', ascending: true)
          .limit(limit);

      final list = <ChatMessage>[];
      for (final row in (data as List).whereType<Map<String, dynamic>>()) {
        final normalized = await _withHttpAttachments(row);
        list.add(
          ChatMessage.fromMap(normalized, currentUid: _sb.auth.currentUser?.id),
        );
      }
      unawaited(_markDeliveredFor(list));
      return list;
    } catch (_) {
      final data = await _sb
          .from(_tblMsgs)
          .select(
            'id, conversation_id, sender_uid, sender_email, kind, body, text, edited, deleted, created_at, edited_at, deleted_at, reply_to_message_id, reply_to_snippet, mentions, attachments',
          )
          .eq('conversation_id', conversationId)
          .or('deleted.is.false,deleted.is.null')
          .lt('created_at', beforeCreatedAt.toUtc().toIso8601String())
          .order('created_at', ascending: true)
          .limit(limit);

      final list = <ChatMessage>[];
      for (final row in (data as List).whereType<Map<String, dynamic>>()) {
        final normalized = await _withHttpAttachments(row);
        list.add(
          ChatMessage.fromMap(normalized, currentUid: _sb.auth.currentUser?.id),
        );
      }
      unawaited(_markDeliveredFor(list));
      return list;
    }
  }

  Future<List<ChatGroupInvitation>> fetchMyGroupInvitations({
    bool pendingOnly = true,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null) return const <ChatGroupInvitation>[];
    try {
      final rows = await _sb
          .from('v_chat_group_invitations_for_me')
          .select()
          .order('created_at', ascending: false);
      final list = (rows as List)
          .whereType<Map<String, dynamic>>()
          .map(ChatGroupInvitation.fromMap)
          .toList();
      if (!pendingOnly) return list;
      return list.where((inv) => inv.isPending).toList();
    } catch (_) {
      return const <ChatGroupInvitation>[];
    }
  }

  Future<void> acceptGroupInvitation(String invitationId) async {
    if (invitationId.isEmpty) return;
    try {
      final res = await _sb.rpc(
        'chat_accept_invitation',
        params: {'p_invitation_id': invitationId},
      );
      _ensureInvitationRpcOk(res, 'تعذر قبول الدعوة.');
    } on PostgrestException catch (e) {
      throw ChatInvitationException(e.message ?? 'تعذر قبول الدعوة.');
    }
  }

  Future<void> declineGroupInvitation(
    String invitationId, {
    String? note,
  }) async {
    if (invitationId.isEmpty) return;
    try {
      final res = await _sb.rpc(
        'chat_decline_invitation',
        params: {'p_invitation_id': invitationId, 'p_note': note},
      );
      _ensureInvitationRpcOk(res, 'تعذر رفض الدعوة.');
    } on PostgrestException catch (e) {
      throw ChatInvitationException(e.message ?? 'تعذر رفض الدعوة.');
    }
  }

  Future<Map<String, String>> fetchAliasMap() async {
    final u = _sb.auth.currentUser;
    if (u == null) return const {};
    try {
      final rows = await _sb
          .from('chat_aliases')
          .select('target_uid, alias')
          .eq('owner_uid', u.id);
      final map = <String, String>{};
      for (final row in (rows as List).whereType<Map<String, dynamic>>()) {
        final target = row['target_uid']?.toString();
        final alias = row['alias']?.toString();
        if (target != null && alias != null && alias.isNotEmpty) {
          map[target] = alias;
        }
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  Future<void> setAlias({
    required String targetUid,
    required String alias,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null || targetUid.isEmpty) return;
    final trimmed = alias.trim();
    if (trimmed.isEmpty) {
      await removeAlias(targetUid);
      return;
    }
    try {
      await _sb.from('chat_aliases').upsert({
        'owner_uid': u.id,
        'target_uid': targetUid,
        'alias': trimmed,
      }, onConflict: 'owner_uid,target_uid');
    } catch (_) {}
  }

  Future<void> removeAlias(String targetUid) async {
    final u = _sb.auth.currentUser;
    if (u == null || targetUid.isEmpty) return;
    try {
      await _sb
          .from('chat_aliases')
          .delete()
          .eq('owner_uid', u.id)
          .eq('target_uid', targetUid);
    } catch (_) {}
  }

  // ======= اشتراك مضبوط لكل محادثة =======
  final Map<String, StreamController<List<ChatMessage>>> _roomCtrls = {};
  final Map<String, RealtimeChannel> _roomChannels = {};
  final Map<String, Map<String, ChatMessage>> _roomCacheById = {};

  Stream<List<ChatMessage>> watchMessages(String conversationId) {
    final existing = _roomCtrls[conversationId];
    if (existing != null) return existing.stream;

    final c = StreamController<List<ChatMessage>>.broadcast();
    _roomCtrls[conversationId] = c;
    _roomCacheById[conversationId] = <String, ChatMessage>{};

    unawaited(() async {
      final seed = await fetchMessages(
        conversationId: conversationId,
        limit: 80,
      );
      final map = _roomCacheById[conversationId]!;
      for (final m in seed) {
        map[m.id] = m;
      }
      if (!c.isClosed) c.add(_sortedAsc(map.values.toList()));
    }());

    final ch = _sb
        .channel('room:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: _tblMsgs,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (payload) async {
            final ev = payload.eventType;
            final newRow =
                (payload.newRecord as Map<String, dynamic>?) ?? const {};
            final oldRow =
                (payload.oldRecord as Map<String, dynamic>?) ?? const {};
            final map = _roomCacheById[conversationId]!;
            String? id;

            if (ev == PostgresChangeEvent.insert ||
                ev == PostgresChangeEvent.update) {
              id = newRow['id']?.toString();
              if (id != null && newRow['deleted'] != true) {
                var row = newRow;
                try {
                  row = await _withHttpAttachments(row);
                } catch (_) {}
                var msg = ChatMessage.fromMap(
                  row,
                  currentUid: _sb.auth.currentUser?.id,
                );

                if (msg.kind == ChatMessageKind.image &&
                    msg.attachments.isEmpty) {
                  try {
                    final attsRows = await _sb
                        .from(_tblAtts)
                        .select(
                          'id, message_id, bucket, path, mime_type, size_bytes, width, height, created_at',
                        )
                        .eq('message_id', msg.id);
                    final normalized = await _normalizeAttachmentsToHttp(
                      (attsRows as List)
                          .whereType<Map<String, dynamic>>()
                          .toList(),
                    );
                    if (normalized.isNotEmpty) {
                      msg = msg.copyWith(
                        attachments: normalized
                            .map(ChatAttachment.fromMap)
                            .toList(),
                      );
                    }
                  } catch (_) {}
                }
                map[id] = msg;
                if (ev == PostgresChangeEvent.insert) {
                  unawaited(_markDeliveredFor([msg]));
                }
              }
              if (ev == PostgresChangeEvent.update &&
                  newRow['deleted'] == true &&
                  id != null) {
                map.remove(id);
              }
            } else if (ev == PostgresChangeEvent.delete) {
              id = oldRow['id']?.toString();
              if (id != null) map.remove(id);
            }

            if (!c.isClosed) c.add(_sortedAsc(map.values.toList()));
          },
        );

    _roomChannels[conversationId] = ch;

    unawaited(
      Future.microtask(() {
        ch.subscribe();
      }),
    );

    c.onCancel = () async {
      _roomCtrls.remove(conversationId);
      _roomCacheById.remove(conversationId);
      final chan = _roomChannels.remove(conversationId);
      if (chan != null) {
        try {
          await chan.unsubscribe();
        } catch (_) {}
        try {
          _sb.removeChannel(chan);
        } catch (_) {}
      }
    };

    return c.stream;
  }

  List<ChatMessage> _sortedAsc(List<ChatMessage> list) {
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  Future<void> _markDeliveredFor(List<ChatMessage> messages) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null || messages.isEmpty) return;

    final ids = messages
        .where((m) => m.senderUid != uid)
        .map((m) => m.id)
        .where((id) => id.isNotEmpty && !id.startsWith('local-'))
        .toSet()
        .toList();

    if (ids.isEmpty) return;

    try {
      await _sb.rpc('chat_mark_delivered', params: {'p_message_ids': ids});
    } catch (_) {}
  }

  /// إرسال نص — يأخذ account_id من المحادثة
  Future<ChatMessage> sendText({
    required String conversationId,
    required String body,
    int? localSeq,
    String? replyToMessageId,
    String? replyToSnippet,
    List<String>? mentionsEmails,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null) throw 'لا يوجد مستخدم مسجّل الدخول.';
    final me = await _myAccountRow();
    final senderEmail = _bestSenderEmail(me.email);
    if (senderEmail == null || senderEmail.isEmpty) {
      throw 'لا أستطيع تحديد بريد المرسل.';
    }
    final deviceId = await _determineDeviceId(me.deviceId);
    final now = DateTime.now().toUtc();

    // حرصاً على وجود local_id دائم
    final seq =
        localSeq ??
        (await _nextSeqForMe()) ??
        DateTime.now().microsecondsSinceEpoch;

    // ✅ account_id من المحادثة أولًا
    final convAcc =
        (await _conversationAccountId(conversationId)) ?? (me.accountId ?? '');

    final payload = <String, dynamic>{
      'conversation_id': conversationId,
      'sender_uid': u.id,
      'sender_email': senderEmail,
      'kind': ChatMessageKind.text.dbValue,
      'body': body,
      'text': body,
      'created_at': now.toIso8601String(),
      'device_id': deviceId,
      'local_id': seq,
      if (convAcc.isNotEmpty) 'account_id': convAcc,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (replyToSnippet != null && replyToSnippet.trim().isNotEmpty)
        'reply_to_snippet': replyToSnippet.trim(),
      if (mentionsEmails != null && mentionsEmails.isNotEmpty)
        'mentions': mentionsEmails,
    };

    final inserted = await _sb
        .from(_tblMsgs)
        .upsert(payload, onConflict: 'device_id,local_id')
        .select()
        .single();

    await _updateConversationLastSummary(
      conversationId: conversationId,
      lastAt: now,
      snippet: _buildSnippet(kind: ChatMessageKind.text, body: body),
    );

    var out = ChatMessage.fromMap(
      inserted,
      currentUid: _sb.auth.currentUser?.id,
    );
    if (out.senderUid == u.id) {
      out = out.copyWith(status: ChatMessageStatus.sent);
    }
    return out;
  }

  Future<Map<String, dynamic>> _uploadOneAttachmentRow({
    required String conversationId,
    required String messageId,
    required File file,
  }) async {
    final name = _friendlyFileName(file);
    final mime = _guessMime(name);
    final path = 'attachments/$conversationId/$messageId/$name';

    await _uploadToStorage(
      path: path,
      file: file,
      options: FileOptions(contentType: mime, upsert: false),
    );

    final stat = await file.stat();
    final insertedAtt = await _sb
        .from(_tblAtts)
        .insert({
          'message_id': messageId,
          'bucket': attachmentsBucket,
          'path': path,
          'mime_type': mime,
          'size_bytes': stat.size,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        })
        .select()
        .single();

    return insertedAtt;
  }

  Future<Map<String, dynamic>> _makeInlineAttachmentJson({
    required String conversationId,
    required String messageId,
    required File file,
  }) async {
    final name = _friendlyFileName(file);
    final mime = _guessMime(name);
    final path = 'attachments/$conversationId/$messageId/$name';

    await _uploadToStorage(
      path: path,
      file: file,
      options: FileOptions(contentType: mime, upsert: false),
    );

    final url = await _signedOrPublicUrl(attachmentsBucket, path);
    final stat = await file.stat();

    return {
      'type': 'image',
      'url': url,
      'bucket': attachmentsBucket,
      'path': path,
      'mime_type': mime,
      'size_bytes': stat.size,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'extra': const <String, dynamic>{},
    };
  }

  /// إرسال صور — يأخذ account_id من المحادثة
  Future<List<ChatMessage>> sendImages({
    required String conversationId,
    required List<File> files,
    String? optionalText,
    int? localSeq,
    String? replyToMessageId,
    String? replyToSnippet,
    List<String>? mentionsEmails,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null) throw 'لا يوجد مستخدم مسجّل الدخول.';
    if (files.isEmpty &&
        (optionalText == null || optionalText.trim().isEmpty)) {
      throw 'لا يوجد شيء لإرساله.';
    }

    final me = await _myAccountRow();
    final senderEmail = _bestSenderEmail(me.email);
    if (senderEmail == null || senderEmail.isEmpty) {
      throw 'لا أستطيع تحديد بريد المرسل.';
    }
    final deviceId = await _determineDeviceId(me.deviceId);

    final sent = <ChatMessage>[];

    if (optionalText != null && optionalText.trim().isNotEmpty) {
      final textMsg = await sendText(
        conversationId: conversationId,
        body: optionalText.trim(),
        localSeq: null,
        replyToMessageId: replyToMessageId,
        replyToSnippet: replyToSnippet,
        mentionsEmails: mentionsEmails,
      );
      sent.add(textMsg);
    }

    if (files.isNotEmpty) {
      double totalBytes = 0;
      const maxTotal = AppConstants.chatMaxAttachmentBytes;
      const maxSingle = AppConstants.chatMaxSingleAttachmentBytes;
      final oversized = <String>[];
      for (final file in files) {
        final friendlyName = _friendlyFileName(file);
        try {
          final size = await file.length();
          totalBytes += size;
          if (maxSingle != null && size > maxSingle) {
            oversized.add(friendlyName);
          }
        } catch (_) {
          oversized.add(friendlyName);
        }
      }
      if (maxTotal != null && totalBytes > maxTotal) {
        final kb = (totalBytes / 1024).toStringAsFixed(1);
        final mbCap = (maxTotal / (1024 * 1024)).toStringAsFixed(1);
        throw 'حجم المرفقات الحالي ($kb KB) يتجاوز الحد الأقصى ($mbCap MB).';
      }
      if (oversized.isNotEmpty) {
        final joined = oversized.join(', ');
        final cap = maxSingle == null
            ? ''
            : ' (${(maxSingle / (1024 * 1024)).toStringAsFixed(1)} MB لكل ملف)';
        throw 'الملفات التالية كبيرة جداً: $joined$cap';
      }

      final now = DateTime.now().toUtc();

      // ✅ نضمن دومًا وجود local_id
      final seq =
          localSeq ??
          (await _nextSeqForMe()) ??
          DateTime.now().microsecondsSinceEpoch;

      final convAcc =
          (await _conversationAccountId(conversationId)) ??
          (me.accountId ?? '');

      final payload = <String, dynamic>{
        'conversation_id': conversationId,
        'sender_uid': u.id,
        'sender_email': senderEmail,
        'kind': ChatMessageKind.image.dbValue,
        'body': null,
        'text': null,
        'created_at': now.toIso8601String(),
        'device_id': deviceId,
        'local_id': seq,
        if (convAcc.isNotEmpty) 'account_id': convAcc,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
        if (replyToSnippet != null && replyToSnippet.trim().isNotEmpty)
          'reply_to_snippet': replyToSnippet.trim(),
        if (mentionsEmails != null && mentionsEmails.isNotEmpty)
          'mentions': mentionsEmails,
      };

      final inserted = await _sb
          .from(_tblMsgs)
          .upsert(payload, onConflict: 'device_id,local_id')
          .select()
          .single();

      var msg = ChatMessage.fromMap(
        inserted,
        currentUid: _sb.auth.currentUser?.id,
      );
      if (msg.senderUid == u.id) {
        msg = msg.copyWith(status: ChatMessageStatus.sent);
      }

      final uploadedRows = <Map<String, dynamic>>[];
      bool usedAttachmentsTable = true;
      try {
        for (final f in files) {
          final att = await _uploadOneAttachmentRow(
            conversationId: conversationId,
            messageId: msg.id,
            file: f,
          );
          uploadedRows.add(att);
        }
      } catch (_) {
        usedAttachmentsTable = false;
      }

      if (usedAttachmentsTable) {
        final normalized = await _normalizeAttachmentsToHttp(uploadedRows);
        msg = msg.copyWith(
          attachments: normalized.map(ChatAttachment.fromMap).toList(),
        );
      } else {
        final inline = <Map<String, dynamic>>[];
        for (final f in files) {
          inline.add(
            await _makeInlineAttachmentJson(
              conversationId: conversationId,
              messageId: msg.id,
              file: f,
            ),
          );
        }
        await _sb
            .from(_tblMsgs)
            .update({'attachments': inline})
            .eq('id', msg.id);
        final normalized = await _normalizeAttachmentsToHttp(inline);
        msg = msg.copyWith(
          attachments: normalized.map(ChatAttachment.fromMap).toList(),
        );
      }

      await _updateConversationLastSummary(
        conversationId: conversationId,
        lastAt: msg.createdAt,
        snippet: _buildSnippet(kind: ChatMessageKind.image),
      );

      sent.add(msg);
    }

    return sent;
  }

  Future<void> editMessage({
    required String messageId,
    required String newBody,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null) throw 'لا يوجد مستخدم.';
    final row = await _sb
        .from(_tblMsgs)
        .select('id, conversation_id, sender_uid, kind')
        .eq('id', messageId)
        .maybeSingle();
    if (row == null) throw 'الرسالة غير موجودة.';
    if (row['sender_uid']?.toString() != u.id) {
      throw 'لا يمكنك تعديل رسالة ليست لك.';
    }
    if ((row['kind']?.toString() ?? '') != ChatMessageKind.text.dbValue) {
      throw 'لا يمكن تعديل هذا النوع من الرسائل.';
    }

    await _sb
        .from(_tblMsgs)
        .update({
          'body': newBody,
          'text': newBody,
          'edited': true,
          'edited_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', messageId);

    await refreshConversationLastSummary(row['conversation_id'].toString());
  }

  /// حذف الرسالة (بدون حذف مرفقاتها من التخزين)
  Future<void> deleteMessage(String messageId) async {
    final u = _sb.auth.currentUser;
    if (u == null) throw 'لا يوجد مستخدم.';
    final row = await _sb
        .from(_tblMsgs)
        .select('id, conversation_id, sender_uid')
        .eq('id', messageId)
        .maybeSingle();
    if (row == null) throw 'الرسالة غير موجودة.';
    if (row['sender_uid']?.toString() != u.id) {
      throw 'لا يمكنك حذف رسالة ليست لك.';
    }

    await _sb
        .from(_tblMsgs)
        .update({
          'deleted': true,
          'deleted_at': DateTime.now().toUtc().toIso8601String(),
          'body': null,
          'text': null,
        })
        .eq('id', messageId);

    await refreshConversationLastSummary(row['conversation_id'].toString());
  }

  /// حذف مرفقات رسالة من Storage + صفوفها من chat_attachments (اختياري)
  Future<void> deleteMessageAttachments(String messageId) async {
    try {
      final atts = await _sb
          .from(_tblAtts)
          .select('id, bucket, path, message_id')
          .eq('message_id', messageId);
      final list = (atts as List).whereType<Map<String, dynamic>>().toList();
      if (list.isEmpty) return;

      final files = list
          .map((e) => (e['path']?.toString() ?? ''))
          .where((p) => p.isNotEmpty)
          .toList();
      if (files.isNotEmpty) {
        try {
          await _sb.storage.from(attachmentsBucket).remove(files);
        } catch (_) {}
      }

      final ids = list
          .map((e) => (e['id']?.toString() ?? ''))
          .where((id) => id.isNotEmpty)
          .toList();
      if (ids.isNotEmpty) {
        try {
          await _sb.from(_tblAtts).delete().inFilter('id', ids);
        } catch (_) {}
      }
    } catch (_) {
      // تجاهل
    }
  }

  // --- تهريب نص البحث قبل ilike ---
  String _escapeIlike(String q) =>
      q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  Future<List<ChatMessage>> searchMessages({
    required String conversationId,
    required String query,
    int limit = 100,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const <ChatMessage>[];

    final esc = _escapeIlike(q);

    // ملاحظة: تجنّب استدعاء .or مرتين لأن الثانية قد تستبدل الأولى.
    // نستبعد المحذوفين عبر not('deleted','is', true) ثم نستخدم or للبحث.
    final rows = await _sb
        .from(_tblMsgs)
        .select(
          'id, conversation_id, sender_uid, sender_email, kind, '
          'body, text, edited, deleted, created_at, edited_at, deleted_at, '
          'reply_to_message_id, reply_to_snippet, mentions, attachments',
        )
        .eq('conversation_id', conversationId)
        .not('deleted', 'is', true)
        .or('body.ilike.%$esc%,text.ilike.%$esc%')
        .order('created_at', ascending: true)
        .limit(limit);

    final list = <ChatMessage>[];
    for (final r in (rows as List).whereType<Map<String, dynamic>>()) {
      final normalized = await _withHttpAttachments(r);
      list.add(
        ChatMessage.fromMap(normalized, currentUid: _sb.auth.currentUser?.id),
      );
    }
    return list;
  }

  // --------------------------------------------------------------
  // Read state
  // --------------------------------------------------------------
  Future<DateTime?> markReadUpToLatest(String conversationId) async {
    final u = _sb.auth.currentUser;
    if (u == null) return null;

    final lastRow = await _sb
        .from(_tblMsgs)
        .select('id, created_at')
        .eq('conversation_id', conversationId)
        .or('deleted.is.false,deleted.is.null')
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (lastRow == null) return null;

    // ✅ استخدم زمن إنشاء آخر رسالة كوقت قراءة
    final lastCreated =
        DateTime.tryParse(lastRow['created_at'].toString())?.toUtc() ??
        DateTime.now().toUtc();

    await _sb.from(_tblReads).upsert({
      'conversation_id': conversationId,
      'user_uid': u.id,
      'last_read_message_id': lastRow['id'].toString(),
      'last_read_at': lastCreated.toIso8601String(),
    }, onConflict: 'conversation_id,user_uid');

    return lastCreated;
  }

  // --------------------------------------------------------------
  // Typing (كما هو)
  // --------------------------------------------------------------
  RealtimeChannel? _typingBus;
  bool _typingBusSubscribed = false;
  final Map<String, StreamController<Map<String, dynamic>>> _typingCtlrs = {};
  final Map<String, DateTime> _lastTypingPingByConv = {};

  Future<void> _ensureTypingBus() async {
    if (_typingBus != null && _typingBusSubscribed) return;
    _typingBus ??= _sb.channel(
      'typing-bus',
      opts: const RealtimeChannelConfig(ack: false),
    );

    _typingBus!.onBroadcast(
      event: 'typing',
      callback: (payload, [_]) {
        if (payload is! Map) return;
        final cid =
            (payload['conversation_id'] ??
                    payload['conversationId'] ??
                    payload['cid'])
                ?.toString();
        if (cid == null) return;
        final c = _typingCtlrs[cid];
        if (c != null && !c.isClosed) {
          c.add(Map<String, dynamic>.from(payload));
        }
      },
    );

    try {
      await _typingBus!.subscribe();
      _typingBusSubscribed = true;
    } catch (_) {
      _typingBusSubscribed = false;
    }
  }

  Stream<Map<String, dynamic>> typingStream(String conversationId) {
    final key = conversationId;
    final existing = _typingCtlrs[key];
    if (existing != null) return existing.stream;

    final controller = StreamController<Map<String, dynamic>>.broadcast();
    _typingCtlrs[key] = controller;

    unawaited(_ensureTypingBus());

    controller.onCancel = () {
      _typingCtlrs.remove(key);
    };

    return controller.stream;
  }

  Future<void> pingTyping(String conversationId, {required bool typing}) async {
    final u = _sb.auth.currentUser;
    if (u == null) return;

    await _ensureTypingBus();
    if (!_typingBusSubscribed) return;

    final now = DateTime.now();
    final last = _lastTypingPingByConv[conversationId];
    if (last != null && now.difference(last).inMilliseconds < 1200) return;
    _lastTypingPingByConv[conversationId] = now;

    final me = await _myAccountRow();

    await _typingBus!.sendBroadcastMessage(
      event: 'typing',
      payload: {
        'conversation_id': conversationId,
        'uid': u.id,
        'email': (_bestSenderEmail(me.email) ?? '').toLowerCase(),
        'typing': typing,
        'ts': now.toUtc().toIso8601String(),
      },
    );
  }

  Future<void> disposeTyping() async {
    for (final c in _typingCtlrs.values) {
      try {
        await c.close();
      } catch (_) {}
    }
    _typingCtlrs.clear();
    _lastTypingPingByConv.clear();
    if (_typingBus != null) {
      try {
        await _typingBus!.unsubscribe();
      } catch (_) {}
    }
    _typingBus = null;
    _typingBusSubscribed = false;
  }

  // --------------------------------------------------------------
  // Reactions (كما هو)
  // --------------------------------------------------------------
  RealtimeChannel? _reactBus;
  bool _reactBusSubscribed = false;
  final Map<String, StreamController<List<ChatReaction>>> _reactCtlrs = {};
  final Map<String, List<ChatReaction>> _reactCache = {};

  Future<void> _ensureReactBus() async {
    if (_reactBus != null && _reactBusSubscribed) return;

    _reactBus ??= _sb.channel(
      'react-bus',
      opts: const RealtimeChannelConfig(ack: false),
    );

    _reactBus!.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: _tblReacts,
      callback: (payload) {
        final ev = payload.eventType;
        final Map<String, dynamic> newRow =
            (payload.newRecord as Map<String, dynamic>?) ??
            const <String, dynamic>{};
        final Map<String, dynamic> oldRow =
            (payload.oldRecord as Map<String, dynamic>?) ??
            const <String, dynamic>{};

        String? mid;
        if (ev == PostgresChangeEvent.delete) {
          mid = oldRow['message_id']?.toString();
        } else {
          mid = newRow['message_id']?.toString();
        }
        if (mid == null || !_reactCtlrs.containsKey(mid)) return;

        final current = List<ChatReaction>.from(
          _reactCache[mid] ?? const <ChatReaction>[],
        );

        if (ev == PostgresChangeEvent.insert) {
          current.add(ChatReaction.fromMap(newRow));
        } else if (ev == PostgresChangeEvent.delete) {
          final uid = oldRow['user_uid']?.toString();
          final emoji = oldRow['emoji']?.toString();
          current.removeWhere(
            (r) => r.userUid == uid && r.emoji == (emoji ?? r.emoji),
          );
        } else if (ev == PostgresChangeEvent.update) {
          final oldUid = oldRow['user_uid']?.toString();
          final oldEmoji = oldRow['emoji']?.toString();
          current.removeWhere(
            (r) => r.userUid == oldUid && r.emoji == (oldEmoji ?? r.emoji),
          );
          current.add(ChatReaction.fromMap(newRow));
        }

        _reactCache[mid] = current;
        final c = _reactCtlrs[mid];
        if (c != null && !c.isClosed) {
          c.add(List<ChatReaction>.from(current));
        }
      },
    );

    try {
      await _reactBus!.subscribe();
      _reactBusSubscribed = true;
    } catch (_) {
      _reactBusSubscribed = false;
    }
  }

  Future<List<ChatReaction>> getReactions(String messageId) async {
    try {
      final rows = await _sb
          .from(_tblReacts)
          .select('message_id, user_uid, emoji, created_at')
          .eq('message_id', messageId)
          .order('created_at', ascending: true);
      return (rows as List)
          .whereType<Map<String, dynamic>>()
          .map(ChatReaction.fromMap)
          .toList();
    } catch (_) {
      return const <ChatReaction>[];
    }
  }

  Stream<List<ChatReaction>> watchReactions(String messageId) {
    final existing = _reactCtlrs[messageId];
    if (existing != null) return existing.stream;

    final c = StreamController<List<ChatReaction>>.broadcast();
    _reactCtlrs[messageId] = c;

    unawaited(() async {
      await _ensureReactBus();
      final seed = await getReactions(messageId);
      _reactCache[messageId] = List<ChatReaction>.from(seed);
      if (!c.isClosed) c.add(seed);
    }());

    c.onCancel = () {
      _reactCtlrs.remove(messageId);
      _reactCache.remove(messageId);
    };

    return c.stream;
  }

  Future<void> addReaction({
    required String messageId,
    required String emoji,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null) return;
    try {
      await _sb.from(_tblReacts).insert({
        'message_id': messageId,
        'user_uid': u.id,
        'emoji': emoji,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  Future<void> removeReaction({
    required String messageId,
    required String emoji,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null) return;
    try {
      await _sb
          .from(_tblReacts)
          .delete()
          .eq('message_id', messageId)
          .eq('user_uid', u.id)
          .eq('emoji', emoji);
    } catch (_) {}
  }

  Future<void> toggleReaction({
    required String messageId,
    required String emoji,
  }) async {
    final u = _sb.auth.currentUser;
    if (u == null) return;
    try {
      final exists = await _sb
          .from(_tblReacts)
          .select('message_id')
          .eq('message_id', messageId)
          .eq('user_uid', u.id)
          .eq('emoji', emoji)
          .maybeSingle();
      if (exists != null) {
        await removeReaction(messageId: messageId, emoji: emoji);
      } else {
        await addReaction(messageId: messageId, emoji: emoji);
      }
    } catch (_) {}
  }

  @Deprecated('Use watchReactions(messageId) consolidated bus instead.')
  Stream<List<ChatReaction>> watchReactionsLegacy(String messageId) =>
      watchReactions(messageId);
}

class _ChatParticipant {
  final String conversationId;
  final String userUid;
  final String? email;

  const _ChatParticipant({
    required this.conversationId,
    required this.userUid,
    this.email,
  });

  factory _ChatParticipant.fromMap(Map<String, dynamic> m) => _ChatParticipant(
    conversationId: m['conversation_id']?.toString() ?? '',
    userUid: m['user_uid']?.toString() ?? '',
    email: m['email']?.toString(),
  );
}
