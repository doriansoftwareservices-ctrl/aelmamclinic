// lib/services/chat_service.dart
//
// ChatService — طبقة خدمة شاملة لميزة الدردشة فوق Nhost (GraphQL + Storage).
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

import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:path/path.dart' as p;

import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
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
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/nhost_storage_service.dart';
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

  GraphQLClient get _gql => NhostGraphqlService.client;
  final NhostStorageService _storage = NhostStorageService();
  final Map<String, ({String url, DateTime expiresAt})> _signedUrlCache = {};

  // --------------------------------------------------------------
  // ثوابت
  // --------------------------------------------------------------
  static const String attachmentsBucket = AppConstants.chatBucketName;

  static const _tblConvs = 'chat_conversations';
  static const _tblParts = 'chat_participants';
  static const _tblMsgs = 'chat_messages';
  static const _tblReads = 'chat_reads';
  static const _tblAccUsers = 'account_users';
  static const _tblAtts = 'chat_attachments';
  static const _tblReacts = 'chat_reactions';

  // --------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------
  String? get currentUserId => NhostManager.client.auth.currentUser?.id;
  String? get currentUserEmail => NhostManager.client.auth.currentUser?.email;

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

  String _formatGqlError(OperationException error) {
    if (error.graphqlErrors.isNotEmpty) {
      return error.graphqlErrors.map((e) => e.message).join(' | ');
    }
    return error.toString();
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

  Future<Map<String, dynamic>> _runMutation(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final result = await _gql.mutate(
      MutationOptions(
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

  Stream<QueryResult> _runSubscription(
    String doc,
    Map<String, dynamic> variables,
  ) {
    return _gql.subscribe(
      SubscriptionOptions(
        document: gql(doc),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
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

  Map<String, dynamic>? _rowFromData(
    Map<String, dynamic> data,
    String key,
  ) {
    final row = data[key];
    if (row is Map) {
      return Map<String, dynamic>.from(row);
    }
    return null;
  }

  static const String _messageSelectFields = '''
    id
    conversation_id
    sender_uid
    sender_email
    kind
    body
    text
    edited
    deleted
    created_at
    edited_at
    deleted_at
    reply_to_message_id
    reply_to_snippet
    mentions
    account_id
    device_id
    local_id
    attachments
    chat_attachments {
      id
      message_id
      bucket
      path
      mime_type
      size_bytes
      width
      height
      created_at
    }
    chat_delivery_receipts {
      user_uid
      delivered_at
    }
  ''';

  Future<ChatMessage> _messageFromRow(Map<String, dynamic> row) async {
    final copy = Map<String, dynamic>.from(row);
    final attRows = (copy['chat_attachments'] as List?) ?? const [];
    final legacyAtts = (copy['attachments'] as List?) ?? const [];
    final attSource = attRows.isNotEmpty ? attRows : legacyAtts;
    if (attSource.isNotEmpty) {
      copy['attachments'] = await _normalizeAttachmentsToHttp(attSource);
    }
    if (copy['delivery_receipts'] == null &&
        copy['chat_delivery_receipts'] != null) {
      copy['delivery_receipts'] = copy['chat_delivery_receipts'];
    }
    return ChatMessage.fromMap(copy, currentUid: currentUserId);
  }

  Future<List<ChatMessage>> _messagesFromRows(List<Map<String, dynamic>> rows) async {
    final list = <ChatMessage>[];
    for (final row in rows) {
      list.add(await _messageFromRow(row));
    }
    return list;
  }

  Future<String> _uploadToStorage({
    required String name,
    required File file,
    required String mimeType,
  }) async {
    try {
      final res = await _storage.uploadFile(
        file: file,
        name: name,
        bucketId: attachmentsBucket,
        mimeType: mimeType,
      );
      final id = res['id']?.toString();
      if (id == null || id.isEmpty) {
        throw ChatAttachmentUploadException('لم يتم استلام معرّف الملف من التخزين.');
      }
      return id;
    } catch (e) {
      throw ChatAttachmentUploadException('فشل رفع المرفقات: $e', cause: e);
    }
  }

  void _ensureInvitationRpcOk(dynamic response, String fallback) {
    Map? row;
    if (response is List && response.isNotEmpty && response.first is Map) {
      row = response.first as Map;
    } else if (response is Map) {
      row = response;
    }
    if (row != null && row['ok'] == true) {
      return;
    }
    final error = row?['error']?.toString();
    throw ChatInvitationException(
      error == null || error.isEmpty ? fallback : error,
    );
  }

  Future<({String? accountId, String? role, String? email, String? deviceId})>
      _myAccountRow() async {
    final uid = currentUserId;
    if (uid == null || uid.isEmpty) {
      return (accountId: null, role: null, email: null, deviceId: null);
    }
    try {
      final preferred = await ActiveAccountStore.readAccountId();
      if (preferred != null && preferred.isNotEmpty) {
        final preferredQuery = '''
        query MyAccountRowPreferred(\$uid: uuid!, \$account: uuid!) {
          account_users(
            where: {user_uid: {_eq: \$uid}, account_id: {_eq: \$account}},
            limit: 1
          ) {
            account_id
            role
            email
            device_id
          }
        }
      ''';
        final preferredData = await _runQuery(
          preferredQuery,
          {'uid': uid, 'account': preferred},
        );
        final preferredRows = (preferredData[_tblAccUsers] as List?) ?? const [];
        if (preferredRows.isNotEmpty) {
          final row = _asJsonMap(preferredRows.first);
          return (
            accountId: row?['account_id']?.toString(),
            role: row?['role']?.toString(),
            email: (row?['email']?.toString() ?? '').toLowerCase(),
            deviceId: row?['device_id']?.toString(),
          );
        }
      }

      final query = '''
        query MyAccountRow(\$uid: uuid!) {
          account_users(
            where: {user_uid: {_eq: \$uid}},
            order_by: {created_at: desc},
            limit: 1
          ) {
            account_id
            role
            email
            device_id
          }
        }
      ''';
      final data = await _runQuery(query, {'uid': uid});
      final rows = (data[_tblAccUsers] as List?) ?? const [];
      final row = rows.isEmpty ? null : _asJsonMap(rows.first);
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
      final query = '''
        query ConversationAccount(\$id: uuid!) {
          $_tblConvs(where: {id: {_eq: \$id}}, limit: 1) {
            account_id
          }
        }
      ''';
      final data = await _runQuery(query, {'id': conversationId});
      final rows = (data[_tblConvs] as List?) ?? const [];
      final row = rows.isEmpty ? null : _asJsonMap(rows.first);
      final v = row?['account_id']?.toString();
      if (v == null || v.isEmpty || v == 'null') return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// يضمن لنا تحديد بريد المرسل.
  String? _bestSenderEmail(String? meEmail) {
    final authEmail = currentUserEmail;
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
      final row = rows.isEmpty ? null : _asJsonMap(rows.first);
      final id = row?['id']?.toString();
      return (id == null || id.isEmpty) ? null : id;
    } catch (_) {
      return null;
    }
  }

  Future<String> _signedOrPublicUrl(String bucket, String path) async {
    if (AppConstants.chatPreferPublicUrls) {
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

  String _safeFileName(String name) {
    final s = name.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_\.\-]'), '_');
    return s.isEmpty ? 'file_${DateTime.now().millisecondsSinceEpoch}' : s;
  }

  String _friendlyFileName(File file, {String fallback = 'file'}) {
    try {
      final uriName =
          file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : null;
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

  String _buildSnippet({required ChatMessageKind kind, String? body}) {
    if (kind == ChatMessageKind.text) {
      final s = (body ?? '').trim();
      if (s.isEmpty) return 'رسالة';
      return s.length > 64 ? '${s.substring(0, 64)}…' : s;
    }
    if (kind == ChatMessageKind.image) return '📷 صورة';
    return 'رسالة';
  }

  Future<Map<String, dynamic>?> _findMessageByTriplet({
    required String conversationId,
    required String deviceId,
    required int localId,
    String? accountId,
  }) async {
    final vars = <String, dynamic>{
      'cid': conversationId,
      'deviceId': deviceId,
      'localId': localId,
    };
    final accountFilter =
        accountId == null ? '' : ', account_id: {_eq: \$accountId}';
    final accountVar =
        accountId == null ? '' : ', \$accountId: uuid!';
    if (accountId != null) {
      vars['accountId'] = accountId;
    }
    final query = '''
      query FindMessageByTriplet(\$cid: uuid!, \$deviceId: String!, \$localId: bigint!$accountVar) {
        $_tblMsgs(
          where: {
            conversation_id: {_eq: \$cid},
            device_id: {_eq: \$deviceId},
            local_id: {_eq: \$localId}$accountFilter
          },
          limit: 1
        ) {
          $_messageSelectFields
        }
      }
    ''';
    try {
      final data = await _runQuery(query, vars);
      final rows = _rowsFromData(data, _tblMsgs);
      return rows.isEmpty ? null : rows.first;
    } catch (_) {
      return null;
    }
  }

  Future<void> _updateConversationLastSummary({
    required String conversationId,
    required DateTime lastAt,
    required String snippet,
  }) async {
    try {
      final mutation = '''
        mutation UpdateConversation(\$id: uuid!, \$lastAt: timestamptz!, \$snippet: String) {
          update_${_tblConvs}(
            where: {id: {_eq: \$id}},
            _set: {last_msg_at: \$lastAt, last_msg_snippet: \$snippet}
          ) {
            affected_rows
          }
        }
      ''';
      await _runMutation(mutation, {
        'id': conversationId,
        'lastAt': lastAt.toUtc().toIso8601String(),
        'snippet': snippet,
      });
    } catch (_) {}
  }

  Future<void> refreshConversationLastSummary(String conversationId) async {
    try {
      final query = '''
        query LastMessage(\$cid: uuid!) {
          $_tblMsgs(
            where: {conversation_id: {_eq: \$cid}, deleted: {_neq: true}},
            order_by: {created_at: desc},
            limit: 1
          ) {
            kind
            body
            created_at
            deleted
          }
        }
      ''';
      final data = await _runQuery(query, {'cid': conversationId});
      final rows = (data[_tblMsgs] as List?) ?? const [];
      final last = rows.isEmpty ? null : _asJsonMap(rows.first);

      if (last == null) {
        final mutation = '''
          mutation ClearLast(\$id: uuid!) {
            update_${_tblConvs}(
              where: {id: {_eq: \$id}},
              _set: {last_msg_at: null, last_msg_snippet: null}
            ) {
              affected_rows
            }
          }
        ''';
        await _runMutation(mutation, {'id': conversationId});
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
    final query = '''
      query FindDM(\$uidA: uuid!, \$uidB: uuid!) {
        $_tblConvs(
          where: {
            is_group: {_eq: false},
            _and: [
              {$_tblParts: {user_uid: {_eq: \$uidA}}},
              {$_tblParts: {user_uid: {_eq: \$uidB}}}
            ]
          },
          limit: 1
        ) {
          id
          is_group
          account_id
          title
          created_at
          created_by
          last_msg_at
          last_msg_snippet
        }
      }
    ''';
    final data = await _runQuery(query, {'uidA': uidA, 'uidB': uidB});
    final rows = (data[_tblConvs] as List?) ?? const [];
    if (rows.isEmpty) return null;
    return ChatConversation.fromMap(Map<String, dynamic>.from(rows.first as Map));
  }

  Future<ChatConversation> startDMWithEmail(String email) async {
    final uid = currentUserId;
    if (uid == null) {
      throw 'لا يوجد مستخدم مسجّل الدخول.';
    }
    final me = await _myAccountRow();
    final myRole = (me.role?.toLowerCase() ?? '');
    final myAcc = (me.accountId ?? '').trim();

    final query = '''
      query FindAccountUser(\$email: String!) {
        $_tblAccUsers(
          where: {email: {_eq: \$email}},
          order_by: {created_at: desc},
          limit: 1
        ) {
          user_uid
          email
          account_id
          role
        }
      }
    ''';
    final data = await _runQuery(query, {'email': email.toLowerCase()});
    final rows = (data[_tblAccUsers] as List?) ?? const [];
    if (rows.isEmpty) {
      throw 'لا يوجد مستخدم بالبريد: $email';
    }
    final targetRow = Map<String, dynamic>.from(rows.first as Map);

    final otherUid = targetRow['user_uid']?.toString() ?? '';
    if (otherUid.isEmpty) {
      throw 'حدث خلل أثناء جلب المستخدم الهدف.';
    }

    final otherEmail = (targetRow['email']?.toString() ?? email).toLowerCase();

    final targetRole = (targetRow['role']?.toString() ?? '').toLowerCase();
    if (targetRole == 'superadmin' && myRole != 'superadmin') {
      throw 'غير مسموح للموظفين مراسلة السوبر أدمن مباشرة.';
    }
    if (otherUid == uid) throw 'لا يمكنك مراسلة نفسك.';

    final existing = await findExistingDMByUids(uidA: uid, uidB: otherUid);
    if (existing != null) return existing;

    String? convAccountId;
    final otherAcc = (targetRow['account_id']?.toString() ?? '').trim();
    if (otherAcc.isNotEmpty && myAcc.isNotEmpty && otherAcc == myAcc) {
      convAccountId = myAcc;
    }
    final convId = _uuidV4();
    final nowIso = DateTime.now().toUtc().toIso8601String();

    final createMutation = '''
      mutation CreateConversation(\$objects: [${_tblConvs}_insert_input!]!) {
        insert_${_tblConvs}(objects: \$objects) {
          returning {
            id
            is_group
            title
            account_id
            created_by
            created_at
            updated_at
            last_msg_at
            last_msg_snippet
          }
        }
      }
    ''';
    final createData = await _runMutation(createMutation, {
      'objects': [
        {
          'id': convId,
          'account_id': convAccountId,
          'is_group': false,
          'title': null,
          'created_by': uid,
          'created_at': nowIso,
          'updated_at': nowIso,
        }
      ],
    });

    final partsMutation = '''
      mutation UpsertParticipants(\$objects: [${_tblParts}_insert_input!]!) {
        insert_${_tblParts}(
          objects: \$objects,
          on_conflict: {
            constraint: chat_participants_pkey,
            update_columns: [email, joined_at]
          }
        ) {
          affected_rows
        }
      }
    ''';
    await _runMutation(partsMutation, {
      'objects': [
        {
          'conversation_id': convId,
          'user_uid': uid,
          'email': (_bestSenderEmail(me.email) ?? '').toLowerCase(),
          'joined_at': nowIso,
        },
        {
          'conversation_id': convId,
          'user_uid': otherUid,
          'email': otherEmail,
          'joined_at': nowIso,
        },
      ],
    });

    final convRows =
        (createData['insert_${_tblConvs}'] as Map?)?['returning'] as List?;
    if (convRows != null && convRows.isNotEmpty) {
      return ChatConversation.fromMap(
        Map<String, dynamic>.from(convRows.first as Map),
      );
    }

    return ChatConversation.fromMap({
      'id': convId,
      'is_group': false,
      'title': null,
      'account_id': convAccountId,
      'created_by': uid,
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
    final uid = currentUserId;
    if (uid == null) throw 'لا يوجد مستخدم مسجّل الدخول.';
    if (title.trim().isEmpty) throw 'اكتب اسم المجموعة.';
    if (memberEmails.isEmpty) throw 'أضِف عضوًا واحدًا على الأقل.';

    final me = await _myAccountRow();
    final myAcc = (me.accountId ?? '').trim();
    if (myAcc.isEmpty) throw 'تعذّر تحديد الحساب الحالي.';

    final members = <({String uid, String email, String accountId})>[];
    for (final e in memberEmails) {
      final query = '''
        query FindMember(\$email: String!) {
          $_tblAccUsers(
            where: {email: {_eq: \$email}},
            order_by: {created_at: desc},
            limit: 1
          ) {
            user_uid
            email
            account_id
          }
        }
      ''';
      final data = await _runQuery(query, {'email': e.toLowerCase()});
      final rows = (data[_tblAccUsers] as List?) ?? const [];
      if (rows.isEmpty) throw 'لا يوجد مستخدم بالبريد: $e';
      final row = Map<String, dynamic>.from(rows.first as Map);
      final memberUid = row['user_uid'].toString();
      if (memberUid == uid) continue;
      final memberAccountId = (row['account_id']?.toString() ?? '').trim();
      if (memberAccountId.isEmpty || memberAccountId != myAcc) {
        throw 'المستخدم $e ليس ضمن نفس حساب العيادة.';
      }
      if (!members.any((m) => m.uid == memberUid)) {
        members.add((
          uid: memberUid,
          email: (row['email']?.toString() ?? e).toLowerCase(),
          accountId: memberAccountId,
        ));
      }
    }

    final convId = _uuidV4();
    final nowIso = DateTime.now().toUtc().toIso8601String();

    final createMutation = '''
      mutation CreateGroup(\$objects: [${_tblConvs}_insert_input!]!) {
        insert_${_tblConvs}(objects: \$objects) {
          returning {
            id
            is_group
            title
            account_id
            created_by
            created_at
            updated_at
            last_msg_at
            last_msg_snippet
          }
        }
      }
    ''';
    await _runMutation(createMutation, {
      'objects': [
        {
          'id': convId,
          'account_id': myAcc,
          'is_group': true,
          'title': title.trim(),
          'created_by': uid,
          'created_at': nowIso,
          'updated_at': nowIso,
        }
      ],
    });

    final participantRows = <Map<String, dynamic>>[
      {
        'conversation_id': convId,
        'user_uid': uid,
        'email': (_bestSenderEmail(me.email) ?? '').toLowerCase(),
        'account_id': myAcc,
        'joined_at': nowIso,
      },
    ];
    final partsMutation = '''
      mutation UpsertParticipants(\$objects: [${_tblParts}_insert_input!]!) {
        insert_${_tblParts}(
          objects: \$objects,
          on_conflict: {
            constraint: chat_participants_pkey,
            update_columns: [email, joined_at]
          }
        ) {
          affected_rows
        }
      }
    ''';
    await _runMutation(partsMutation, {'objects': participantRows});
    if (members.isNotEmpty) {
      final invites = members
          .map(
            (m) => {
              'conversation_id': convId,
              'inviter_uid': uid,
              'invitee_uid': m.uid,
              'invitee_email': m.email.toLowerCase(),
              'created_at': nowIso,
            },
          )
          .toList();

      final inviteMutation = '''
        mutation CreateInvites(\$objects: [chat_group_invitations_insert_input!]!) {
          insert_chat_group_invitations(objects: \$objects) {
            affected_rows
          }
        }
      ''';
      await _runMutation(inviteMutation, {'objects': invites});
    }

    return ChatConversation.fromMap({
      'id': convId,
      'account_id': myAcc,
      'is_group': true,
      'title': title.trim(),
      'created_by': uid,
      'created_at': nowIso,
      'updated_at': nowIso,
      'last_msg_at': null,
      'last_msg_snippet': null,
    });
  }

  Future<List<ConversationListItem>> fetchMyConversationsOverview() async {
    if (currentUserId == null) return const <ConversationListItem>[];
    final query = '''
      query ConversationsOverview {
        v_chat_conversations_for_me(order_by: {last_msg_at: desc}) {
          id
          account_id
          is_group
          title
          created_by
          created_at
          updated_at
          last_msg_at
          last_msg_snippet
          last_message_id
          last_message_kind
          last_message_body
          last_message_created_at
          last_read_at
          unread_count
          last_message_text
        }
      }
    ''';
    final data = await _runQuery(query, const {});
    final rows = (data['v_chat_conversations_for_me'] as List?) ?? const [];
    if (rows.isEmpty) return const <ConversationListItem>[];

    final items = <ConversationListItem>[];
    for (final row in rows.whereType<Map>()) {
      final map = Map<String, dynamic>.from(row);
      final convo = ChatConversation.fromMap(map);
      final lastRead = map['last_read_at'] == null
          ? null
          : DateTime.tryParse(map['last_read_at'].toString())?.toUtc();
      final unread = map['unread_count'];
      final displayTitle = (convo.title ?? '').trim().isNotEmpty
          ? convo.title!.trim()
          : (convo.isGroup ? 'مجموعة' : 'محادثة');
      items.add(
        ConversationListItem(
          conversation: convo,
          displayTitle: displayTitle,
          lastReadAt: lastRead,
          unreadCount: unread is num ? unread.toInt() : 0,
          lastMessageText: (map['last_message_text'] ??
                  map['last_msg_snippet'] ??
                  map['last_message_body'])
              ?.toString(),
        ),
      );
    }

    items.sort((a, b) {
      final aT = a.conversation.lastMsgAt ?? a.conversation.updatedAt;
      final bT = b.conversation.lastMsgAt ?? b.conversation.updatedAt;
      return (bT ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(aT ?? DateTime.fromMillisecondsSinceEpoch(0));
    });

    return items;
  }

  // --------------------------------------------------------------
  // رسائل
  // --------------------------------------------------------------
  Future<List<ChatMessage>> fetchMessages({
    required String conversationId,
    int limit = 40,
  }) async {
    final query = '''
      query FetchMessages(\$cid: uuid!, \$limit: Int!) {
        $_tblMsgs(
          where: {conversation_id: {_eq: \$cid}, deleted: {_neq: true}},
          order_by: {created_at: asc},
          limit: \$limit
        ) {
          $_messageSelectFields
        }
      }
    ''';
    final data = await _runQuery(query, {
      'cid': conversationId,
      'limit': limit,
    });
    final rows = _rowsFromData(data, _tblMsgs);
    final list = await _messagesFromRows(rows);
    unawaited(_markDeliveredFor(list));
    return list;
  }

  Future<List<ChatMessage>> fetchOlderMessages({
    required String conversationId,
    required DateTime beforeCreatedAt,
    int limit = 40,
  }) async {
    final query = '''
      query FetchOlderMessages(\$cid: uuid!, \$before: timestamptz!, \$limit: Int!) {
        $_tblMsgs(
          where: {
            conversation_id: {_eq: \$cid},
            deleted: {_neq: true},
            created_at: {_lt: \$before}
          },
          order_by: {created_at: asc},
          limit: \$limit
        ) {
          $_messageSelectFields
        }
      }
    ''';
    final data = await _runQuery(query, {
      'cid': conversationId,
      'before': beforeCreatedAt.toUtc().toIso8601String(),
      'limit': limit,
    });
    final rows = _rowsFromData(data, _tblMsgs);
    final list = await _messagesFromRows(rows);
    unawaited(_markDeliveredFor(list));
    return list;
  }

  Future<List<ChatGroupInvitation>> fetchMyGroupInvitations({
    bool pendingOnly = true,
  }) async {
    try {
      final query = '''
        query MyInvitations {
          v_chat_group_invitations_for_me(order_by: {created_at: desc}) {
            id
            conversation_id
            inviter_uid
            invitee_uid
            invitee_email
            status
            created_at
            responded_at
            response_note
            title
            is_group
            account_id
            created_by
          }
        }
      ''';
      final data = await _runQuery(query, const {});
      final rows = _rowsFromData(data, 'v_chat_group_invitations_for_me');
      final list = rows.map(ChatGroupInvitation.fromMap).toList();
      if (!pendingOnly) return list;
      return list.where((inv) => inv.isPending).toList();
    } catch (_) {
      return const <ChatGroupInvitation>[];
    }
  }

  Future<void> acceptGroupInvitation(String invitationId) async {
    if (invitationId.isEmpty) return;
    try {
      final mutation = '''
        mutation AcceptInvitation(\$id: uuid!) {
          chat_accept_invitation(args: {p_invitation_id: \$id}) {
            ok
            error
          }
        }
      ''';
      final data = await _runMutation(mutation, {'id': invitationId});
      final res = data['chat_accept_invitation'];
      _ensureInvitationRpcOk(res, 'تعذر قبول الدعوة.');
    } on OperationException catch (e) {
      throw ChatInvitationException(_formatGqlError(e));
    }
  }

  Future<void> declineGroupInvitation(
    String invitationId, {
    String? note,
  }) async {
    if (invitationId.isEmpty) return;
    try {
      final mutation = '''
        mutation DeclineInvitation(\$id: uuid!, \$note: String) {
          chat_decline_invitation(args: {p_invitation_id: \$id, p_note: \$note}) {
            ok
            error
          }
        }
      ''';
      final data = await _runMutation(mutation, {
        'id': invitationId,
        'note': note,
      });
      final res = data['chat_decline_invitation'];
      _ensureInvitationRpcOk(res, 'تعذر رفض الدعوة.');
    } on OperationException catch (e) {
      throw ChatInvitationException(_formatGqlError(e));
    }
  }

  Future<Map<String, String>> fetchAliasMap() async {
    try {
      final uid = currentUserId;
      if (uid == null) return const {};
      final query = '''
        query MyAliases(\$uid: uuid!) {
          chat_aliases(where: {owner_uid: {_eq: \$uid}}) {
            target_uid
            alias
          }
        }
      ''';
      final data = await _runQuery(query, {'uid': uid});
      final rows = _rowsFromData(data, 'chat_aliases');
      final map = <String, String>{};
      for (final row in rows) {
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
    final uid = currentUserId;
    if (uid == null || targetUid.isEmpty) return;
    final trimmed = alias.trim();
    if (trimmed.isEmpty) {
      await removeAlias(targetUid);
      return;
    }
    try {
      final mutation = '''
        mutation UpsertAlias(\$objects: [chat_aliases_insert_input!]!) {
          insert_chat_aliases(
            objects: \$objects,
            on_conflict: {
              constraint: chat_aliases_pkey,
              update_columns: [alias]
            }
          ) {
            affected_rows
          }
        }
      ''';
      await _runMutation(mutation, {
        'objects': [
          {
            'owner_uid': uid,
            'target_uid': targetUid,
            'alias': trimmed,
          }
        ],
      });
    } catch (_) {}
  }

  Future<void> removeAlias(String targetUid) async {
    final uid = currentUserId;
    if (uid == null || targetUid.isEmpty) return;
    try {
      final mutation = '''
        mutation DeleteAlias(\$owner: uuid!, \$target: uuid!) {
          delete_chat_aliases(
            where: {owner_uid: {_eq: \$owner}, target_uid: {_eq: \$target}}
          ) {
            affected_rows
          }
        }
      ''';
      await _runMutation(mutation, {'owner': uid, 'target': targetUid});
    } catch (_) {}
  }

  // ======= اشتراك مضبوط لكل محادثة =======
  final Map<String, StreamController<List<ChatMessage>>> _roomCtrls = {};
  final Map<String, StreamSubscription<QueryResult>> _roomSubs = {};

  Stream<List<ChatMessage>> watchMessages(String conversationId) {
    final existing = _roomCtrls[conversationId];
    if (existing != null) return existing.stream;

    final c = StreamController<List<ChatMessage>>.broadcast();
    _roomCtrls[conversationId] = c;

    unawaited(() async {
      final seed = await fetchMessages(
        conversationId: conversationId,
        limit: 80,
      );
      if (!c.isClosed) c.add(_sortedAsc(seed));
    }());

    final query = '''
      subscription RoomMessages(\$cid: uuid!) {
        $_tblMsgs(
          where: {conversation_id: {_eq: \$cid}, deleted: {_neq: true}},
          order_by: {created_at: asc}
        ) {
          $_messageSelectFields
        }
      }
    ''';

    final sub = _runSubscription(query, {'cid': conversationId}).listen(
      (result) async {
        if (result.hasException) return;
        final data = result.data ?? const <String, dynamic>{};
        final rows = _rowsFromData(data, _tblMsgs);
        final list = await _messagesFromRows(rows);
        if (!c.isClosed) c.add(_sortedAsc(list));
        unawaited(_markDeliveredFor(list));
      },
    );

    _roomSubs[conversationId] = sub;

    c.onCancel = () async {
      _roomCtrls.remove(conversationId);
      final sub = _roomSubs.remove(conversationId);
      if (sub != null) {
        try {
          await sub.cancel();
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
    final uid = currentUserId;
    if (uid == null || messages.isEmpty) return;

    final ids = messages
        .where((m) => m.senderUid != uid)
        .map((m) => m.id)
        .where((id) => id.isNotEmpty && !id.startsWith('local-'))
        .toSet()
        .toList();

    if (ids.isEmpty) return;

    try {
      final mutation = '''
        mutation MarkDelivered(\$ids: [uuid!]!) {
          chat_mark_delivered(args: {p_message_ids: \$ids}) {
            ok
            error
          }
        }
      ''';
      await _runMutation(mutation, {'ids': ids});
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
    final uid = currentUserId;
    if (uid == null) throw 'لا يوجد مستخدم مسجّل الدخول.';
    final me = await _myAccountRow();
    final senderEmail = _bestSenderEmail(me.email);
    if (senderEmail == null || senderEmail.isEmpty) {
      throw 'لا أستطيع تحديد بريد المرسل.';
    }
    final deviceId = await _determineDeviceId(me.deviceId);
    final now = DateTime.now().toUtc();

    // حرصاً على وجود local_id دائم
    final seq = localSeq ??
        (await _nextSeqForMe()) ??
        DateTime.now().microsecondsSinceEpoch;

    // ✅ account_id من المحادثة أولًا
    final convAcc =
        (await _conversationAccountId(conversationId)) ?? (me.accountId ?? '');

    final payload = <String, dynamic>{
      'conversation_id': conversationId,
      'sender_uid': uid,
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

    final mutation = '''
      mutation InsertMessage(\$object: ${_tblMsgs}_insert_input!) {
        insert_${_tblMsgs}_one(object: \$object) {
          $_messageSelectFields
        }
      }
    ''';
    Map<String, dynamic>? row;
    try {
      final data = await _runMutation(mutation, {'object': payload});
      row = _rowFromData(data, 'insert_${_tblMsgs}_one');
    } catch (_) {
      final existing = await _findMessageByTriplet(
        conversationId: conversationId,
        deviceId: deviceId,
        localId: seq,
        accountId: convAcc.isNotEmpty ? convAcc : null,
      );
      row = existing;
    }

    if (row == null) {
      throw 'تعذر حفظ الرسالة.';
    }

    await _updateConversationLastSummary(
      conversationId: conversationId,
      lastAt: now,
      snippet: _buildSnippet(kind: ChatMessageKind.text, body: body),
    );

    var out = await _messageFromRow(row);
    if (out.senderUid == uid) {
      out = out.copyWith(status: ChatMessageStatus.sent);
    }
    return out;
  }

  Future<Map<String, dynamic>> _uploadOneAttachmentRow({
    required String conversationId,
    required String messageId,
    required File file,
    String? accountId,
  }) async {
    final name = _friendlyFileName(file);
    final mime = _guessMime(name);
    final storageName = 'attachments/$conversationId/$messageId/$name';

    final fileId = await _uploadToStorage(
      name: storageName,
      file: file,
      mimeType: mime,
    );

    final stat = await file.stat();
    final payload = <String, dynamic>{
      'message_id': messageId,
      'bucket': attachmentsBucket,
      'path': fileId,
      'mime_type': mime,
      'size_bytes': stat.size,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      if (accountId != null && accountId.isNotEmpty) 'account_id': accountId,
    };

    final mutation = '''
      mutation InsertAttachment(\$object: ${_tblAtts}_insert_input!) {
        insert_${_tblAtts}_one(object: \$object) {
          id
          message_id
          bucket
          path
          mime_type
          size_bytes
          width
          height
          created_at
        }
      }
    ''';
    try {
      final data = await _runMutation(mutation, {'object': payload});
      final row = _rowFromData(data, 'insert_${_tblAtts}_one');
      return row ?? payload;
    } catch (_) {
      return payload;
    }
  }

  Future<Map<String, dynamic>> _makeInlineAttachmentJson({
    required String conversationId,
    required String messageId,
    required File file,
  }) async {
    final name = _friendlyFileName(file);
    final mime = _guessMime(name);
    final storageName = 'attachments/$conversationId/$messageId/$name';
    final fileId = await _uploadToStorage(
      name: storageName,
      file: file,
      mimeType: mime,
    );

    final url = await _signedOrPublicUrl(attachmentsBucket, fileId);
    final stat = await file.stat();

    return {
      'type': 'image',
      'url': url,
      'bucket': attachmentsBucket,
      'path': fileId,
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
    final uid = currentUserId;
    if (uid == null) throw 'لا يوجد مستخدم مسجّل الدخول.';
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
      final seq = localSeq ??
          (await _nextSeqForMe()) ??
          DateTime.now().microsecondsSinceEpoch;

      final convAcc = (await _conversationAccountId(conversationId)) ??
          (me.accountId ?? '');

      final payload = <String, dynamic>{
        'conversation_id': conversationId,
        'sender_uid': uid,
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

      final mutation = '''
        mutation InsertImageMessage(\$object: ${_tblMsgs}_insert_input!) {
          insert_${_tblMsgs}_one(object: \$object) {
            $_messageSelectFields
          }
        }
      ''';
      Map<String, dynamic>? row;
      try {
        final data = await _runMutation(mutation, {'object': payload});
        row = _rowFromData(data, 'insert_${_tblMsgs}_one');
      } catch (_) {
        final existing = await _findMessageByTriplet(
          conversationId: conversationId,
          deviceId: deviceId,
          localId: seq,
          accountId: convAcc.isNotEmpty ? convAcc : null,
        );
        row = existing;
      }
      if (row == null) throw 'تعذر إرسال الرسالة.';

      var msg = await _messageFromRow(row);
      if (msg.senderUid == uid) {
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
            accountId: convAcc.isNotEmpty ? convAcc : null,
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
        final updateMutation = '''
          mutation UpdateMessageAttachments(\$id: uuid!, \$attachments: jsonb!) {
            update_${_tblMsgs}_by_pk(
              pk_columns: {id: \$id},
              _set: {attachments: \$attachments}
            ) {
              id
            }
          }
        ''';
        try {
          await _runMutation(updateMutation, {
            'id': msg.id,
            'attachments': inline,
          });
        } catch (_) {}
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
    final uid = currentUserId;
    if (uid == null) throw 'لا يوجد مستخدم.';
    final query = '''
      query MessageMeta(\$id: uuid!) {
        ${_tblMsgs}_by_pk(id: \$id) {
          id
          conversation_id
          sender_uid
          kind
        }
      }
    ''';
    final data = await _runQuery(query, {'id': messageId});
    final row = _rowFromData(data, '${_tblMsgs}_by_pk');
    if (row == null) throw 'الرسالة غير موجودة.';
    if (row['sender_uid']?.toString() != uid) {
      throw 'لا يمكنك تعديل رسالة ليست لك.';
    }
    if ((row['kind']?.toString() ?? '') != ChatMessageKind.text.dbValue) {
      throw 'لا يمكن تعديل هذا النوع من الرسائل.';
    }

    final mutation = '''
      mutation EditMessage(\$id: uuid!, \$body: String!, \$editedAt: timestamptz!) {
        update_${_tblMsgs}_by_pk(
          pk_columns: {id: \$id},
          _set: {body: \$body, text: \$body, edited: true, edited_at: \$editedAt}
        ) {
          id
        }
      }
    ''';
    await _runMutation(mutation, {
      'id': messageId,
      'body': newBody,
      'editedAt': DateTime.now().toUtc().toIso8601String(),
    });

    await refreshConversationLastSummary(row['conversation_id'].toString());
  }

  /// حذف الرسالة (بدون حذف مرفقاتها من التخزين)
  Future<void> deleteMessage(String messageId) async {
    final uid = currentUserId;
    if (uid == null) throw 'لا يوجد مستخدم.';
    final query = '''
      query MessageMeta(\$id: uuid!) {
        ${_tblMsgs}_by_pk(id: \$id) {
          id
          conversation_id
          sender_uid
        }
      }
    ''';
    final data = await _runQuery(query, {'id': messageId});
    final row = _rowFromData(data, '${_tblMsgs}_by_pk');
    if (row == null) throw 'الرسالة غير موجودة.';
    if (row['sender_uid']?.toString() != uid) {
      throw 'لا يمكنك حذف رسالة ليست لك.';
    }

    final mutation = '''
      mutation DeleteMessage(\$id: uuid!, \$deletedAt: timestamptz!) {
        update_${_tblMsgs}_by_pk(
          pk_columns: {id: \$id},
          _set: {deleted: true, deleted_at: \$deletedAt, body: null, text: null}
        ) {
          id
        }
      }
    ''';
    await _runMutation(mutation, {
      'id': messageId,
      'deletedAt': DateTime.now().toUtc().toIso8601String(),
    });

    await refreshConversationLastSummary(row['conversation_id'].toString());
  }

  /// حذف مرفقات رسالة من Storage + صفوفها من chat_attachments (اختياري)
  Future<void> deleteMessageAttachments(String messageId) async {
    try {
      final query = '''
        query AttachmentsForMessage(\$id: uuid!) {
          $_tblAtts(where: {message_id: {_eq: \$id}}) {
            id
            bucket
            path
            message_id
          }
        }
      ''';
      final data = await _runQuery(query, {'id': messageId});
      final list = _rowsFromData(data, _tblAtts);
      if (list.isEmpty) return;

      final files = list
          .map((e) => (e['path']?.toString() ?? ''))
          .where((p) => p.isNotEmpty)
          .toList();
      if (files.isNotEmpty) {
        try {
          for (final id in files) {
            await _storage.deleteFile(id);
          }
        } catch (_) {}
      }

      final ids = list
          .map((e) => (e['id']?.toString() ?? ''))
          .where((id) => id.isNotEmpty)
          .toList();
      if (ids.isNotEmpty) {
        try {
          final mutation = '''
            mutation DeleteAttachments(\$ids: [uuid!]!) {
              delete_${_tblAtts}(where: {id: {_in: \$ids}}) {
                affected_rows
              }
            }
          ''';
          await _runMutation(mutation, {'ids': ids});
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
    final pattern = '%$esc%';
    final queryDoc = '''
      query SearchMessages(\$cid: uuid!, \$pattern: String!, \$limit: Int!) {
        $_tblMsgs(
          where: {
            conversation_id: {_eq: \$cid},
            deleted: {_neq: true},
            _or: [
              {body: {_ilike: \$pattern}},
              {text: {_ilike: \$pattern}}
            ]
          },
          order_by: {created_at: asc},
          limit: \$limit
        ) {
          $_messageSelectFields
        }
      }
    ''';
    final data = await _runQuery(queryDoc, {
      'cid': conversationId,
      'pattern': pattern,
      'limit': limit,
    });
    final rows = _rowsFromData(data, _tblMsgs);
    return await _messagesFromRows(rows);
  }

  // --------------------------------------------------------------
  // Read state
  // --------------------------------------------------------------
  Future<DateTime?> markReadUpToLatest(String conversationId) async {
    final uid = currentUserId;
    if (uid == null) return null;

    final query = '''
      query LatestMessage(\$cid: uuid!) {
        $_tblMsgs(
          where: {conversation_id: {_eq: \$cid}, deleted: {_neq: true}},
          order_by: {created_at: desc},
          limit: 1
        ) {
          id
          created_at
        }
      }
    ''';
    final data = await _runQuery(query, {'cid': conversationId});
    final rows = _rowsFromData(data, _tblMsgs);
    final lastRow = rows.isEmpty ? null : rows.first;
    if (lastRow == null) return null;

    // ✅ استخدم زمن إنشاء آخر رسالة كوقت قراءة
    final lastCreated =
        DateTime.tryParse(lastRow['created_at'].toString())?.toUtc() ??
            DateTime.now().toUtc();

    final mutation = '''
      mutation UpsertRead(\$object: ${_tblReads}_insert_input!) {
        insert_${_tblReads}(
          objects: [\$object],
          on_conflict: {
            constraint: chat_reads_pkey,
            update_columns: [last_read_message_id, last_read_at]
          }
        ) {
          affected_rows
        }
      }
    ''';
    await _runMutation(mutation, {
      'object': {
        'conversation_id': conversationId,
        'user_uid': uid,
        'last_read_message_id': lastRow['id'].toString(),
        'last_read_at': lastCreated.toIso8601String(),
      },
    });

    return lastCreated;
  }

  // --------------------------------------------------------------
  // Typing (Nhost)
  // --------------------------------------------------------------
  final Map<String, StreamController<Map<String, dynamic>>> _typingCtlrs = {};
  final Map<String, StreamSubscription<QueryResult>> _typingSubs = {};
  final Map<String, DateTime> _lastTypingPingByConv = {};

  Stream<Map<String, dynamic>> typingStream(String conversationId) {
    final key = conversationId;
    final existing = _typingCtlrs[key];
    if (existing != null) return existing.stream;

    final controller = StreamController<Map<String, dynamic>>.broadcast();
    _typingCtlrs[key] = controller;

    final query = '''
      subscription TypingActive(\$cid: uuid!) {
        v_chat_typing_active(where: {conversation_id: {_eq: \$cid}}) {
          conversation_id
          user_uid
          email
          updated_at
        }
      }
    ''';
    final sub = _runSubscription(query, {'cid': conversationId}).listen(
      (result) {
        if (result.hasException) return;
        final data = result.data ?? const <String, dynamic>{};
        final rows = _rowsFromData(data, 'v_chat_typing_active');
        final active = <String>[];
        final emails = <String, String>{};
        for (final row in rows) {
          final uid = row['user_uid']?.toString();
          if (uid == null || uid.isEmpty) continue;
          active.add(uid);
          final email = row['email']?.toString();
          if (email != null && email.isNotEmpty) {
            emails[uid] = email;
          }
        }
        if (!controller.isClosed) {
          controller.add({
            'conversation_id': conversationId,
            'active_uids': active,
            'emails': emails,
            'ts': DateTime.now().toUtc().toIso8601String(),
          });
        }
      },
    );
    _typingSubs[key] = sub;

    controller.onCancel = () {
      _typingCtlrs.remove(key);
      final sub = _typingSubs.remove(key);
      if (sub != null) {
        unawaited(sub.cancel());
      }
    };

    return controller.stream;
  }

  Future<void> pingTyping(String conversationId, {required bool typing}) async {
    final uid = currentUserId;
    if (uid == null) return;

    final now = DateTime.now();
    final last = _lastTypingPingByConv[conversationId];
    if (last != null && now.difference(last).inMilliseconds < 1200) return;
    _lastTypingPingByConv[conversationId] = now;

    final me = await _myAccountRow();
    final mutation = '''
      mutation UpsertTyping(\$object: chat_typing_insert_input!) {
        insert_chat_typing(
          objects: [\$object],
          on_conflict: {
            constraint: chat_typing_pkey,
            update_columns: [typing, updated_at, email]
          }
        ) {
          affected_rows
        }
      }
    ''';
    try {
      await _runMutation(mutation, {
        'object': {
          'conversation_id': conversationId,
          'user_uid': uid,
          'email': (_bestSenderEmail(me.email) ?? '').toLowerCase(),
          'typing': typing,
          'updated_at': now.toUtc().toIso8601String(),
        }
      });
    } catch (_) {}
  }

  Future<void> disposeTyping() async {
    for (final c in _typingCtlrs.values) {
      try {
        await c.close();
      } catch (_) {}
    }
    _typingCtlrs.clear();
    _lastTypingPingByConv.clear();
    for (final sub in _typingSubs.values) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    _typingSubs.clear();
  }

  // --------------------------------------------------------------
  // Reactions (Nhost)
  // --------------------------------------------------------------
  final Map<String, StreamController<List<ChatReaction>>> _reactCtlrs = {};
  final Map<String, StreamSubscription<QueryResult>> _reactSubs = {};

  Future<List<ChatReaction>> getReactions(String messageId) async {
    try {
      final query = '''
        query MessageReactions(\$id: uuid!) {
          $_tblReacts(
            where: {message_id: {_eq: \$id}},
            order_by: {created_at: asc}
          ) {
            message_id
            user_uid
            emoji
            created_at
          }
        }
      ''';
      final data = await _runQuery(query, {'id': messageId});
      final rows = _rowsFromData(data, _tblReacts);
      return rows.map(ChatReaction.fromMap).toList();
    } catch (_) {
      return const <ChatReaction>[];
    }
  }

  Stream<List<ChatReaction>> watchReactions(String messageId) {
    final existing = _reactCtlrs[messageId];
    if (existing != null) return existing.stream;

    final c = StreamController<List<ChatReaction>>.broadcast();
    _reactCtlrs[messageId] = c;

    final query = '''
      subscription WatchReactions(\$id: uuid!) {
        $_tblReacts(
          where: {message_id: {_eq: \$id}},
          order_by: {created_at: asc}
        ) {
          message_id
          user_uid
          emoji
          created_at
        }
      }
    ''';
    final sub = _runSubscription(query, {'id': messageId}).listen(
      (result) {
        if (result.hasException) return;
        final data = result.data ?? const <String, dynamic>{};
        final rows = _rowsFromData(data, _tblReacts);
        final list = rows.map(ChatReaction.fromMap).toList();
        if (!c.isClosed) c.add(list);
      },
    );
    _reactSubs[messageId] = sub;

    c.onCancel = () {
      _reactCtlrs.remove(messageId);
      final sub = _reactSubs.remove(messageId);
      if (sub != null) {
        unawaited(sub.cancel());
      }
    };

    return c.stream;
  }

  Future<void> addReaction({
    required String messageId,
    required String emoji,
  }) async {
    final uid = currentUserId;
    if (uid == null) return;
    try {
      final mutation = '''
        mutation AddReaction(\$object: ${_tblReacts}_insert_input!) {
          insert_${_tblReacts}_one(object: \$object) {
            message_id
          }
        }
      ''';
      await _runMutation(mutation, {
        'object': {
          'message_id': messageId,
          'user_uid': uid,
          'emoji': emoji,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        }
      });
    } catch (_) {}
  }

  Future<void> removeReaction({
    required String messageId,
    required String emoji,
  }) async {
    final uid = currentUserId;
    if (uid == null) return;
    try {
      final mutation = '''
        mutation DeleteReaction(\$mid: uuid!, \$uid: uuid!, \$emoji: String!) {
          delete_${_tblReacts}(
            where: {
              message_id: {_eq: \$mid},
              user_uid: {_eq: \$uid},
              emoji: {_eq: \$emoji}
            }
          ) {
            affected_rows
          }
        }
      ''';
      await _runMutation(mutation, {
        'mid': messageId,
        'uid': uid,
        'emoji': emoji,
      });
    } catch (_) {}
  }

  Future<void> toggleReaction({
    required String messageId,
    required String emoji,
  }) async {
    final uid = currentUserId;
    if (uid == null) return;
    try {
      final query = '''
        query HasReaction(\$mid: uuid!, \$uid: uuid!, \$emoji: String!) {
          $_tblReacts(
            where: {
              message_id: {_eq: \$mid},
              user_uid: {_eq: \$uid},
              emoji: {_eq: \$emoji}
            },
            limit: 1
          ) {
            message_id
          }
        }
      ''';
      final data = await _runQuery(query, {
        'mid': messageId,
        'uid': uid,
        'emoji': emoji,
      });
      final rows = _rowsFromData(data, _tblReacts);
      if (rows.isNotEmpty) {
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
