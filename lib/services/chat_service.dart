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

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/models/chat_invitation.dart';
import 'package:aelmamclinic/models/chat_models.dart'
    show
        ChatAttachment,
        ChatAttachmentType,
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
  String _attachmentDbValue(ChatAttachmentType type) {
    return type == ChatAttachmentType.image ? 'image' : 'file';
  }

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

  Future<ChatConversation?> _tryStartDmRpc(String otherUid) async {
    const mutation = r'''
      mutation StartDm($other: uuid!) {
        chat_start_dm(args: {p_other_uid: $other}) {
          id
        }
      }
    ''';
    try {
      final data = await _runMutation(mutation, {'other': otherUid});
      final rows = data['chat_start_dm'] as List?;
      final id = rows != null && rows.isNotEmpty
          ? (rows.first as Map)['id']?.toString()
          : null;
      if (id == null || id.isEmpty) return null;
      const query = r'''
        query ConvById($id: uuid!) {
          chat_conversations_by_pk(id: $id) {
            id
            is_group
            title
            account_id
            is_frozen
            admins_only
            created_by
            created_at
            updated_at
            last_msg_at
            last_msg_snippet
          }
        }
      ''';
      final convData = await _runQuery(query, {'id': id});
      final row = convData['chat_conversations_by_pk'];
      if (row is Map) {
        return ChatConversation.fromMap(Map<String, dynamic>.from(row));
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<Map<String, String>?> fetchSupportAgent() async {
    const query = r'''
      query SupportAgent {
        chat_support_agent {
          user_uid
          display_name
        }
      }
    ''';
    final data = await _runQuery(query, const {});
    final rows = data['chat_support_agent'] as List?;
    if (rows == null || rows.isEmpty) return null;
    final row = rows.first as Map;
    final uid = row['user_uid']?.toString() ?? '';
    if (uid.isEmpty) return null;
    final name = row['display_name']?.toString().trim();
    return {
      'user_uid': uid,
      'display_name': (name == null || name.isEmpty) ? 'خدمة العملاء' : name,
    };
  }

  Future<ChatConversation> startDMWithUid(String otherUid) async {
    final uid = currentUserId;
    if (uid == null || uid.isEmpty) {
      throw 'لا يوجد مستخدم مسجّل الدخول.';
    }
    if (otherUid.isEmpty) {
      throw 'لا يوجد مستخدم هدف.';
    }
    if (otherUid == uid) {
      throw 'لا يمكنك مراسلة نفسك.';
    }

    final existing = await findExistingDMByUids(uidA: uid, uidB: otherUid);
    if (existing != null) return existing;

    final rpcConv = await _tryStartDmRpc(otherUid);
    if (rpcConv != null) return rpcConv;

    throw 'تعذّر إنشاء محادثة الدعم. حاول لاحقًا.';
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

  bool _messageSchemaChecked = false;
  bool _includeChatAttachments = AppConstants.chatAllowAttachments;
  bool _includeDeliveryReceipts = true;

  String _messageSelectFields() {
    final attBlock = _includeChatAttachments
        ? '''
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
    '''
        : '';
    final receiptBlock = _includeDeliveryReceipts
        ? '''
    chat_delivery_receipts {
      user_uid
      delivered_at
    }
    '''
        : '';
    return '''
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
    client_msg_id
    attachments
    $attBlock
    $receiptBlock
  ''';
  }

  Future<void> _ensureMessageSchemaSupport() async {
    if (_messageSchemaChecked) return;
    if (!AppConstants.chatAllowAttachments) {
      _includeChatAttachments = false;
      _messageSchemaChecked = true;
      return;
    }
    _messageSchemaChecked = true;
    try {
      const query = '''
        query MessageSchemaFields {
          __type(name: "chat_messages") {
            fields { name }
          }
        }
      ''';
      final data = await _runQuery(query, const <String, dynamic>{});
      final fields = ((data['__type']?['fields'] as List?) ?? const [])
          .map((e) => (e as Map)['name']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toSet();
      _includeChatAttachments = fields.contains('chat_attachments');
      _includeDeliveryReceipts = fields.contains('chat_delivery_receipts');
    } catch (_) {
      // keep defaults
    }
  }

  bool _updateMessageFieldSupport(OperationException error) {
    var changed = false;
    for (final err in error.graphqlErrors) {
      final msg = err.message;
      if (_includeChatAttachments &&
          msg.contains("field 'chat_attachments' not found in type: 'chat_messages'")) {
        _includeChatAttachments = false;
        changed = true;
      }
      if (_includeDeliveryReceipts &&
          msg.contains("field 'chat_delivery_receipts' not found in type: 'chat_messages'")) {
        _includeDeliveryReceipts = false;
        changed = true;
      }
    }
    return changed;
  }

  Future<Map<String, dynamic>> _runMessageQuery(
    String Function(String fields) build,
    Map<String, dynamic> variables,
  ) async {
    await _ensureMessageSchemaSupport();
    try {
      return await _runQuery(build(_messageSelectFields()), variables);
    } on OperationException catch (e) {
      if (_updateMessageFieldSupport(e)) {
        return await _runQuery(build(_messageSelectFields()), variables);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _runMessageMutation(
    String Function(String fields) build,
    Map<String, dynamic> variables,
  ) async {
    await _ensureMessageSchemaSupport();
    try {
      return await _runMutation(build(_messageSelectFields()), variables);
    } on OperationException catch (e) {
      if (_updateMessageFieldSupport(e)) {
        return await _runMutation(build(_messageSelectFields()), variables);
      }
      rethrow;
    }
  }

  Future<ChatMessage> _messageFromRow(Map<String, dynamic> row) async {
    final copy = Map<String, dynamic>.from(row);
    if (!AppConstants.chatAllowAttachments) {
      copy.remove('attachments');
      copy.remove('chat_attachments');
      return ChatMessage.fromMap(copy, currentUid: currentUserId);
    }
    final attRows = (copy['chat_attachments'] as List?) ?? const [];
    final legacyAtts = (copy['attachments'] as List?) ?? const [];
    bool legacyHasFileId = false;
    for (final item in legacyAtts) {
      if (item is! Map) continue;
      final direct = item['file_id']?.toString();
      final url = item['url']?.toString();
      final extra = item['extra'];
      final extraId =
          (extra is Map) ? extra['file_id']?.toString() : null;
      if ((direct != null && direct.isNotEmpty) ||
          (extraId != null && extraId.isNotEmpty) ||
          (url != null && url.isNotEmpty)) {
        legacyHasFileId = true;
        break;
      }
    }
    final attSource = (legacyHasFileId && legacyAtts.isNotEmpty)
        ? legacyAtts
        : (attRows.isNotEmpty ? attRows : legacyAtts);
    if (attSource.isNotEmpty) {
      copy['attachments'] = await _normalizeAttachmentsToHttp(attSource);
    }
    if (copy['delivery_receipts'] == null &&
        copy['chat_delivery_receipts'] != null) {
      copy['delivery_receipts'] = copy['chat_delivery_receipts'];
    }
    return ChatMessage.fromMap(copy, currentUid: currentUserId);
  }

  Future<List<ChatMessage>> _messagesFromRows(
      List<Map<String, dynamic>> rows) async {
    final list = <ChatMessage>[];
    for (final row in rows) {
      list.add(await _messageFromRow(row));
    }
    return list;
  }

  Future<List<Map<String, dynamic>>> _hydrateMessageAttachments(
    List<Map<String, dynamic>> rows,
  ) async {
    if (_includeChatAttachments || rows.isEmpty) return rows;

    final ids = rows
        .map((row) => row['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return rows;

    try {
      final query = '''
        query MessageAttachments(\$ids: [uuid!]!) {
          $_tblAtts(where: {message_id: {_in: \$ids}}) {
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
      final data = await _runQuery(query, {'ids': ids});
      final attRows = _rowsFromData(data, _tblAtts);
      if (attRows.isEmpty) return rows;

      final byMessage = <String, List<Map<String, dynamic>>>{};
      for (final att in attRows) {
        final mid = att['message_id']?.toString();
        if (mid == null || mid.isEmpty) continue;
        byMessage.putIfAbsent(mid, () => <Map<String, dynamic>>[]).add(att);
      }

      for (final row in rows) {
        final mid = row['id']?.toString();
        if (mid != null && byMessage.containsKey(mid)) {
          row['chat_attachments'] = byMessage[mid];
        }
      }
    } catch (_) {
      // ignore attachment hydration failures
    }

    return rows;
  }

  Future<String> _uploadToStorage({
    required String name,
    required File file,
    required String mimeType,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final res = await _storage.uploadFile(
        file: file,
        name: name,
        bucketId: attachmentsBucket,
        mimeType: mimeType,
        metadata: metadata,
      );
      final id = res['id']?.toString();
      if (id == null || id.isEmpty) {
        throw ChatAttachmentUploadException(
            'لم يتم استلام معرّف الملف من التخزين.');
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
        final preferredRows =
            (preferredData[_tblAccUsers] as List?) ?? const [];
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

    if (_looksLikeUuid(path)) {
      return _storage.publicFileUrl(path);
    }
    return '';
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
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
      return 'image/heic';
    }
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.doc')) return 'application/msword';
    if (lower.endsWith('.docx')) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (lower.endsWith('.xls')) return 'application/vnd.ms-excel';
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.ppt')) return 'application/vnd.ms-powerpoint';
    if (lower.endsWith('.pptx')) {
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    }
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.csv')) return 'text/csv';
    return 'application/octet-stream';
  }

  Future<File> _ensureSupportedImageFile(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    if (ext != '.heic' && ext != '.heif') return file;
    try {
      final dir = await getTemporaryDirectory();
      final target = p.join(
        dir.path,
        'chat_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final converted = await FlutterImageCompress.compressAndGetFile(
        file.path,
        target,
        format: CompressFormat.jpeg,
        quality: 85,
      );
      if (converted == null) {
        throw 'صيغة HEIC غير مدعومة. رجاءً اختر صورة بصيغة JPG.';
      }
      return File(converted.path);
    } catch (_) {
      throw 'صيغة HEIC غير مدعومة. رجاءً اختر صورة بصيغة JPG.';
    }
  }

  Future<List<File>> prepareImageFiles(List<File> files) async {
    final prepared = <File>[];
    for (final file in files) {
      prepared.add(await _ensureSupportedImageFile(file));
    }
    return prepared;
  }

  Future<List<Map<String, dynamic>>> _normalizeAttachmentsToHttp(
    List<dynamic> rawList,
  ) async {
    final result = <Map<String, dynamic>>[];
    for (final e in rawList.whereType<Map<String, dynamic>>()) {
      final bucket = e['bucket']?.toString();
      final path = e['path']?.toString();
      String? fileId = e['file_id']?.toString();
      final extra = e['extra'];
      if ((fileId == null || fileId.isEmpty) && extra is Map) {
        final v = extra['file_id']?.toString();
        if (v != null && v.isNotEmpty) {
          fileId = v;
        }
      }
      String url = '';
      if (fileId != null && fileId.isNotEmpty && _looksLikeUuid(fileId)) {
        final signed = await _storage.createSignedUrl(
          fileId,
          expiresInSeconds: AppConstants.storageSignedUrlTTLSeconds,
        );
        url = (signed != null && signed.isNotEmpty)
            ? signed
            : _storage.publicFileUrl(fileId);
      } else if (bucket != null && path != null) {
        url = await _signedOrPublicUrl(bucket, path);
      } else {
        url = (e['url']?.toString() ?? '');
      }
      if (url.isEmpty && bucket != null && path != null) {
        url = 'storage://$bucket/$path';
      }
      final mime = (e['mime_type'] ?? e['mimeType'])?.toString() ?? '';
      final inferredType = mime.toLowerCase().startsWith('image/')
          ? _attachmentDbValue(ChatAttachmentType.image)
          : _attachmentDbValue(ChatAttachmentType.file);
      Map<String, dynamic>? normalizedExtra;
      if (extra is Map) {
        normalizedExtra = Map<String, dynamic>.from(extra);
      }
      if (fileId != null && fileId.isNotEmpty) {
        normalizedExtra ??= <String, dynamic>{};
        normalizedExtra['file_id'] ??= fileId;
      }

      result.add({
        'id': e['id']?.toString(),
        'type': e['type']?.toString() ?? inferredType,
        'url': url,
        'bucket': bucket,
        'path': path,
        'mime_type': mime,
        'size_bytes': e['size_bytes'],
        'width': e['width'],
        'height': e['height'],
        'created_at': e['created_at'] ?? e['createdAt'],
        'extra': normalizedExtra,
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
    if (kind == ChatMessageKind.file) return '📎 ملف';
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
    final accountVar = accountId == null ? '' : ', \$accountId: uuid!';
    if (accountId != null) {
      vars['accountId'] = accountId;
    }
    try {
      final data = await _runMessageQuery((fields) => '''
        query FindMessageByTriplet(\$cid: uuid!, \$deviceId: String!, \$localId: bigint!$accountVar) {
          $_tblMsgs(
            where: {
              conversation_id: {_eq: \$cid},
              device_id: {_eq: \$deviceId},
              local_id: {_eq: \$localId}$accountFilter
            },
            limit: 1
          ) {
            $fields
          }
        }
      ''', vars);
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
    return ChatConversation.fromMap(
        Map<String, dynamic>.from(rows.first as Map));
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
    if (targetRole == 'superadmin' &&
        myRole != 'superadmin' &&
        myRole != 'owner') {
      throw 'غير مسموح للموظفين مراسلة السوبر أدمن مباشرة.';
    }
    if (otherUid == uid) throw 'لا يمكنك مراسلة نفسك.';

    final existing = await findExistingDMByUids(uidA: uid, uidB: otherUid);
    if (existing != null) return existing;

    final rpcConv = await _tryStartDmRpc(otherUid);
    if (rpcConv != null) return rpcConv;

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
          'is_frozen': false,
          'admins_only': false,
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
          'role': 'owner',
        },
        {
          'conversation_id': convId,
          'user_uid': otherUid,
          'email': otherEmail,
          'joined_at': nowIso,
          'role': 'member',
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
      'is_frozen': false,
      'admins_only': false,
      'created_by': uid,
      'created_at': nowIso,
      'updated_at': nowIso,
      'last_msg_at': null,
      'last_msg_snippet': null,
    });
  }

  void _ensureGroupsEnabled() {
    if (!AppConstants.chatAllowGroups) {
      throw ChatInvitationException(
        'تم إيقاف المحادثات الجماعية في هذا الإصدار.',
      );
    }
  }

  Future<ChatConversation> createGroup({
    required String title,
    required List<String> memberEmails,
  }) async {
    _ensureGroupsEnabled();
    final uid = currentUserId;
    if (uid == null) throw 'لا يوجد مستخدم مسجّل الدخول.';
    if (title.trim().isEmpty) throw 'اكتب اسم المجموعة.';
    if (memberEmails.isEmpty) throw 'أضِف عضوًا واحدًا على الأقل.';

    final me = await _myAccountRow();
    final myAcc = (me.accountId ?? '').trim();
    if (myAcc.isEmpty) throw 'تعذّر تحديد الحساب الحالي.';

    final members = <({String uid, String email, String accountId})>[];
    for (final e in memberEmails) {
      if (e.trim().isEmpty) continue;
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
      if (!members.any((m) => m.uid == memberUid)) {
        members.add((
          uid: memberUid,
          email: (row['email']?.toString() ?? e).toLowerCase(),
          accountId: memberAccountId,
        ));
      }
    }

    if (members.isEmpty) {
      throw 'أضِف عضوًا واحدًا على الأقل.';
    }

    final totalMembers = members.length + 1;
    if (totalMembers > 100) {
      throw 'الحد الأقصى للمجموعة 100 حساب.';
    }

    bool allSameAccount = myAcc.isNotEmpty;
    String? accountCandidate = myAcc;
    for (final m in members) {
      if (m.accountId.isEmpty) {
        allSameAccount = false;
        break;
      }
      if (accountCandidate == null) {
        accountCandidate = m.accountId;
      } else if (accountCandidate != m.accountId) {
        allSameAccount = false;
        break;
      }
    }
    final convAccountId =
        allSameAccount ? accountCandidate : null;

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
          'account_id': convAccountId,
          'is_group': true,
          'title': title.trim(),
          'is_frozen': false,
          'admins_only': false,
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
        'account_id': convAccountId,
        'joined_at': nowIso,
        'role': 'owner',
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
      'account_id': convAccountId,
      'is_group': true,
      'title': title.trim(),
      'is_frozen': false,
      'admins_only': false,
      'created_by': uid,
      'created_at': nowIso,
      'updated_at': nowIso,
      'last_msg_at': null,
      'last_msg_snippet': null,
    });
  }

  // --------------------------------------------------------------
  // إدارة المجموعات (RPC)
  // --------------------------------------------------------------
  Future<void> groupSetTitle({
    required String conversationId,
    required String title,
  }) async {
    _ensureGroupsEnabled();
    final mutation = '''
      mutation GroupSetTitle(\$cid: uuid!, \$title: String!) {
        chat_group_set_title(args: {p_conversation_id: \$cid, p_title: \$title}) {
          ok
          error
        }
      }
    ''';
    final data = await _runMutation(mutation, {
      'cid': conversationId,
      'title': title,
    });
    _assertRpcOk(data, 'chat_group_set_title');
  }

  Future<void> groupSetFrozen({
    required String conversationId,
    required bool isFrozen,
    required bool adminsOnly,
  }) async {
    _ensureGroupsEnabled();
    final mutation = '''
      mutation GroupSetFrozen(\$cid: uuid!, \$frozen: Boolean!, \$adminsOnly: Boolean!) {
        chat_group_set_frozen(args: {
          p_conversation_id: \$cid,
          p_is_frozen: \$frozen,
          p_admins_only: \$adminsOnly
        }) {
          ok
          error
        }
      }
    ''';
    final data = await _runMutation(mutation, {
      'cid': conversationId,
      'frozen': isFrozen,
      'adminsOnly': adminsOnly,
    });
    _assertRpcOk(data, 'chat_group_set_frozen');
  }

  Future<void> groupSetMemberRole({
    required String conversationId,
    required String targetUid,
    required String role,
  }) async {
    _ensureGroupsEnabled();
    final mutation = '''
      mutation GroupSetMemberRole(\$cid: uuid!, \$uid: uuid!, \$role: String!) {
        chat_group_set_member_role(args: {
          p_conversation_id: \$cid,
          p_target_uid: \$uid,
          p_role: \$role
        }) {
          ok
          error
        }
      }
    ''';
    final data = await _runMutation(mutation, {
      'cid': conversationId,
      'uid': targetUid,
      'role': role,
    });
    _assertRpcOk(data, 'chat_group_set_member_role');
  }

  Future<void> groupRemoveMember({
    required String conversationId,
    required String targetUid,
  }) async {
    _ensureGroupsEnabled();
    final mutation = '''
      mutation GroupRemoveMember(\$cid: uuid!, \$uid: uuid!) {
        chat_group_remove_member(args: {
          p_conversation_id: \$cid,
          p_target_uid: \$uid
        }) {
          ok
          error
        }
      }
    ''';
    final data = await _runMutation(mutation, {
      'cid': conversationId,
      'uid': targetUid,
    });
    _assertRpcOk(data, 'chat_group_remove_member');
  }

  Future<void> groupDelete(String conversationId) async {
    _ensureGroupsEnabled();
    final mutation = '''
      mutation GroupDelete(\$cid: uuid!) {
        chat_group_delete(args: {p_conversation_id: \$cid}) {
          ok
          error
        }
      }
    ''';
    final data = await _runMutation(mutation, {'cid': conversationId});
    _assertRpcOk(data, 'chat_group_delete');
  }

  void _assertRpcOk(Map<String, dynamic> data, String key) {
    final rows = data[key] as List?;
    if (rows == null || rows.isEmpty) return;
    final row = rows.first as Map;
    final ok = row['ok'] == true || row['ok']?.toString() == 'true';
    if (!ok) {
      final err = row['error']?.toString();
      if (err != null && err.isNotEmpty) {
        throw err;
      }
    }
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
          is_frozen
          admins_only
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
    if (rows.isEmpty) {
      return _fallbackConversationsByParticipant();
    }

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

  Future<List<ConversationListItem>> _fallbackConversationsByParticipant() async {
    final uid = currentUserId;
    if (uid == null || uid.isEmpty) return const <ConversationListItem>[];

    final partsQuery = '''
      query MyParticipantConversations(\$uid: uuid!) {
        $_tblParts(where: {
          user_uid: {_eq: \$uid},
          archived: {_neq: true},
          is_deleted: {_neq: true}
        }) {
          conversation_id
        }
      }
    ''';
    final partsData = await _runQuery(partsQuery, {'uid': uid});
    final partRows = (partsData[_tblParts] as List?) ?? const [];
    final ids = partRows
        .whereType<Map>()
        .map((e) => (e['conversation_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return const <ConversationListItem>[];

    final convQuery = '''
      query MyConversationsByIds(\$ids: [uuid!]!) {
        $_tblConvs(
          where: {id: {_in: \$ids}, is_deleted: {_neq: true}},
          order_by: {last_msg_at: desc}
        ) {
          id
          account_id
          is_group
          title
          is_frozen
          admins_only
          created_by
          created_at
          updated_at
          last_msg_at
          last_msg_snippet
        }
      }
    ''';
    final convData = await _runQuery(convQuery, {'ids': ids});
    final convRows = (convData[_tblConvs] as List?) ?? const [];
    if (convRows.isEmpty) return const <ConversationListItem>[];

    final readsQuery = '''
      query MyReads(\$ids: [uuid!]!, \$uid: uuid!) {
        $_tblReads(
          where: {
            conversation_id: {_in: \$ids},
            user_uid: {_eq: \$uid}
          }
        ) {
          conversation_id
          last_read_at
        }
      }
    ''';
    Map<String, DateTime?> lastReadByConv = <String, DateTime?>{};
    try {
      final readsData = await _runQuery(readsQuery, {'ids': ids, 'uid': uid});
      final readRows = (readsData[_tblReads] as List?) ?? const [];
      for (final row in readRows.whereType<Map>()) {
        final cid = row['conversation_id']?.toString();
        if (cid == null || cid.isEmpty) continue;
        final ts = row['last_read_at']?.toString();
        lastReadByConv[cid] = ts == null ? null : DateTime.tryParse(ts)?.toUtc();
      }
    } catch (_) {}

    final items = <ConversationListItem>[];
    for (final row in convRows.whereType<Map>()) {
      final map = Map<String, dynamic>.from(row);
      final convo = ChatConversation.fromMap(map);
      final cid = convo.id;
      final displayTitle = (convo.title ?? '').trim().isNotEmpty
          ? convo.title!.trim()
          : (convo.isGroup ? 'مجموعة' : 'محادثة');
      items.add(
        ConversationListItem(
          conversation: convo,
          displayTitle: displayTitle,
          lastReadAt: lastReadByConv[cid],
          unreadCount: 0,
          lastMessageText:
              (map['last_msg_snippet'] ?? map['last_message_text'])?.toString(),
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
    final data = await _runMessageQuery((fields) => '''
      query FetchMessages(\$cid: uuid!, \$limit: Int!) {
        $_tblMsgs(
          where: {conversation_id: {_eq: \$cid}},
          order_by: {created_at: asc},
          limit: \$limit
        ) {
          $fields
        }
      }
    ''', {
      'cid': conversationId,
      'limit': limit,
    });
    final rows = await _hydrateMessageAttachments(_rowsFromData(data, _tblMsgs));
    final list = await _messagesFromRows(rows);
    unawaited(_markDeliveredFor(list));
    return list;
  }

  Future<List<ChatMessage>> fetchOlderMessages({
    required String conversationId,
    required DateTime beforeCreatedAt,
    int limit = 40,
  }) async {
    final data = await _runMessageQuery((fields) => '''
      query FetchOlderMessages(\$cid: uuid!, \$before: timestamptz!, \$limit: Int!) {
        $_tblMsgs(
          where: {
            conversation_id: {_eq: \$cid},
            created_at: {_lt: \$before}
          },
          order_by: {created_at: asc},
          limit: \$limit
        ) {
          $fields
        }
      }
    ''', {
      'cid': conversationId,
      'before': beforeCreatedAt.toUtc().toIso8601String(),
      'limit': limit,
    });
    final rows = await _hydrateMessageAttachments(_rowsFromData(data, _tblMsgs));
    final list = await _messagesFromRows(rows);
    unawaited(_markDeliveredFor(list));
    return list;
  }

  Future<List<ChatGroupInvitation>> fetchMyGroupInvitations({
    bool pendingOnly = true,
  }) async {
    if (!AppConstants.chatAllowGroups) {
      return const <ChatGroupInvitation>[];
    }
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
    _ensureGroupsEnabled();
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
    _ensureGroupsEnabled();
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

  // --------------------------------------------------------------
  // أرشفة/حذف المحادثات للمستخدم الحالي
  // --------------------------------------------------------------
  Future<void> setConversationArchived({
    required String conversationId,
    required bool archived,
  }) async {
    final uid = currentUserId;
    if (uid == null || conversationId.isEmpty) return;
    final mutation = '''
      mutation ArchiveConversation(\$cid: uuid!, \$uid: uuid!, \$archived: Boolean!) {
        update_${_tblParts}(
          where: {conversation_id: {_eq: \$cid}, user_uid: {_eq: \$uid}},
          _set: {archived: \$archived}
        ) {
          affected_rows
        }
      }
    ''';
    await _runMutation(mutation, {
      'cid': conversationId,
      'uid': uid,
      'archived': archived,
    });
  }

  Future<void> deleteConversationForMe({
    required String conversationId,
  }) async {
    final uid = currentUserId;
    if (uid == null || conversationId.isEmpty) return;
    final mutation = '''
      mutation DeleteConversationForMe(\$cid: uuid!, \$uid: uuid!, \$ts: timestamptz!) {
        update_${_tblParts}(
          where: {conversation_id: {_eq: \$cid}, user_uid: {_eq: \$uid}},
          _set: {is_deleted: true, deleted_at: \$ts}
        ) {
          affected_rows
        }
      }
    ''';
    await _runMutation(mutation, {
      'cid': conversationId,
      'uid': uid,
      'ts': DateTime.now().toUtc().toIso8601String(),
    });
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
      await _ensureMessageSchemaSupport();
      final seed = await fetchMessages(
        conversationId: conversationId,
        limit: 80,
      );
      if (!c.isClosed) c.add(_sortedAsc(seed));
      final query = '''
        subscription RoomMessages(\$cid: uuid!) {
          $_tblMsgs(
            where: {conversation_id: {_eq: \$cid}},
            order_by: {created_at: asc}
          ) {
            ${_messageSelectFields()}
          }
        }
      ''';

      final sub = _runSubscription(query, {'cid': conversationId}).listen(
        (result) async {
          if (result.hasException) return;
          final data = result.data ?? const <String, dynamic>{};
          final rows = await _hydrateMessageAttachments(
            _rowsFromData(data, _tblMsgs),
          );
          final list = await _messagesFromRows(rows);
          if (!c.isClosed) c.add(_sortedAsc(list));
          unawaited(_markDeliveredFor(list));
        },
      );

      _roomSubs[conversationId] = sub;
    }());

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

    ChatMessage? lastIncoming;
    for (final m in messages) {
      if (m.senderUid == uid) continue;
      if (m.id.isEmpty || m.id.startsWith('local-')) continue;
      if (lastIncoming == null || m.createdAt.isAfter(lastIncoming.createdAt)) {
        lastIncoming = m;
      }
    }

    if (lastIncoming == null) return;

    await _upsertReadState(
      conversationId: lastIncoming.conversationId,
      lastDeliveredMessageId: lastIncoming.id,
      lastDeliveredAt: lastIncoming.createdAt,
    );
  }

  /// إرسال نص — يأخذ account_id من المحادثة
  Future<ChatMessage> sendText({
    required String conversationId,
    required String body,
    int? localSeq,
    String? clientMsgId,
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
      if (clientMsgId != null && clientMsgId.isNotEmpty)
        'client_msg_id': clientMsgId,
      if (convAcc.isNotEmpty) 'account_id': convAcc,
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (replyToSnippet != null && replyToSnippet.trim().isNotEmpty)
        'reply_to_snippet': replyToSnippet.trim(),
      if (mentionsEmails != null && mentionsEmails.isNotEmpty)
        'mentions': mentionsEmails,
    };

    Map<String, dynamic>? row;
    try {
      final data = await _runMessageMutation((fields) => '''
        mutation InsertMessage(\$object: ${_tblMsgs}_insert_input!) {
          insert_${_tblMsgs}(
            objects: [\$object],
            on_conflict: {
              constraint: chat_messages_conversation_client_msg_id_key,
              update_columns: [body, text, edited, edited_at]
            }
          ) {
            returning {
              $fields
            }
          }
        }
      ''', {'object': payload});
      final ret =
          (data['insert_${_tblMsgs}'] as Map?)?['returning'] as List?;
      if (ret != null && ret.isNotEmpty) {
        row = Map<String, dynamic>.from(ret.first as Map);
      }
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
      metadata: <String, dynamic>{
        'conversation_id': conversationId,
        'message_id': messageId,
      },
    );

    final stat = await file.stat();
    final payload = <String, dynamic>{
      'message_id': messageId,
      'bucket': attachmentsBucket,
      'path': storageName,
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
      final merged = row ?? Map<String, dynamic>.from(payload);
      merged['file_id'] = fileId;
      merged['extra'] = {
        'file_id': fileId,
      };
      return merged;
    } catch (_) {
      final fallback = Map<String, dynamic>.from(payload);
      fallback['file_id'] = fileId;
      fallback['extra'] = {
        'file_id': fileId,
      };
      return fallback;
    }
  }

  Future<Map<String, dynamic>> _makeInlineAttachmentJson({
    required String conversationId,
    required String messageId,
    required File file,
    required ChatAttachmentType attachmentType,
  }) async {
    final name = _friendlyFileName(file);
    final mime = _guessMime(name);
    final storageName = 'attachments/$conversationId/$messageId/$name';
    final fileId = await _uploadToStorage(
      name: storageName,
      file: file,
      mimeType: mime,
      metadata: <String, dynamic>{
        'conversation_id': conversationId,
        'message_id': messageId,
      },
    );

    final signed = await _storage.createSignedUrl(
      fileId,
      expiresInSeconds: AppConstants.storageSignedUrlTTLSeconds,
    );
    final url = (signed != null && signed.isNotEmpty)
        ? signed
        : _storage.publicFileUrl(fileId);
    final stat = await file.stat();

    return {
      'type': _attachmentDbValue(attachmentType),
      'url': url,
      'bucket': attachmentsBucket,
      'path': storageName,
      'mime_type': mime,
      'size_bytes': stat.size,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'extra': <String, dynamic>{
        'file_id': fileId,
      },
    };
  }

  /// إرسال صور — يأخذ account_id من المحادثة
  Future<List<ChatMessage>> sendImages({
    required String conversationId,
    required List<File> files,
    String? optionalText,
    int? localSeq,
    String? clientMsgId,
    String? replyToMessageId,
    String? replyToSnippet,
    List<String>? mentionsEmails,
  }) async {
    if (!AppConstants.chatAllowAttachments) {
      throw ChatAttachmentUploadException('المرفقات معطّلة في هذا الإصدار.');
    }
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
        clientMsgId: clientMsgId == null
            ? null
            : '${clientMsgId}_text',
        replyToMessageId: replyToMessageId,
        replyToSnippet: replyToSnippet,
        mentionsEmails: mentionsEmails,
      );
      sent.add(textMsg);
    }

    if (files.isNotEmpty) {
      final preparedFiles = <File>[];
      for (final file in files) {
        preparedFiles.add(await _ensureSupportedImageFile(file));
      }
      double totalBytes = 0;
      const maxTotal = AppConstants.chatMaxAttachmentBytes;
      const maxSingle = AppConstants.chatMaxSingleAttachmentBytes;
      final oversized = <String>[];
      for (final file in preparedFiles) {
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
        if (clientMsgId != null && clientMsgId.isNotEmpty)
          'client_msg_id': clientMsgId,
        if (convAcc.isNotEmpty) 'account_id': convAcc,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
        if (replyToSnippet != null && replyToSnippet.trim().isNotEmpty)
          'reply_to_snippet': replyToSnippet.trim(),
        if (mentionsEmails != null && mentionsEmails.isNotEmpty)
          'mentions': mentionsEmails,
      };

      Map<String, dynamic>? row;
      try {
        final data = await _runMessageMutation((fields) => '''
          mutation InsertImageMessage(\$object: ${_tblMsgs}_insert_input!) {
            insert_${_tblMsgs}(
              objects: [\$object],
              on_conflict: {
                constraint: chat_messages_conversation_client_msg_id_key,
                update_columns: [edited, edited_at]
              }
            ) {
              returning {
                $fields
              }
            }
          }
        ''', {'object': payload});
        final ret =
            (data['insert_${_tblMsgs}'] as Map?)?['returning'] as List?;
        if (ret != null && ret.isNotEmpty) {
          row = Map<String, dynamic>.from(ret.first as Map);
        }
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
        for (final f in preparedFiles) {
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
        try {
          const updateMutation = '''
            mutation UpdateMessageAttachments(\$id: uuid!, \$attachments: jsonb!) {
              update_${_tblMsgs}_by_pk(
                pk_columns: {id: \$id},
                _set: {attachments: \$attachments}
              ) {
                id
              }
            }
          ''';
          await _runMutation(updateMutation, {
            'id': msg.id,
            'attachments': uploadedRows,
          });
        } catch (_) {}
        final normalized = await _normalizeAttachmentsToHttp(uploadedRows);
        msg = msg.copyWith(
          attachments: normalized.map(ChatAttachment.fromMap).toList(),
        );
      } else {
        final inline = <Map<String, dynamic>>[];
        for (final f in preparedFiles) {
          inline.add(
            await _makeInlineAttachmentJson(
              conversationId: conversationId,
              messageId: msg.id,
              file: f,
              attachmentType: ChatAttachmentType.image,
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

  /// إرسال ملفات — يأخذ account_id من المحادثة
  Future<List<ChatMessage>> sendFiles({
    required String conversationId,
    required List<File> files,
    String? optionalText,
    int? localSeq,
    String? clientMsgId,
    String? replyToMessageId,
    String? replyToSnippet,
    List<String>? mentionsEmails,
  }) async {
    if (!AppConstants.chatAllowAttachments) {
      throw ChatAttachmentUploadException('المرفقات معطّلة في هذا الإصدار.');
    }
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
        clientMsgId: clientMsgId == null
            ? null
            : '${clientMsgId}_text',
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
      final seq = localSeq ??
          (await _nextSeqForMe()) ??
          DateTime.now().microsecondsSinceEpoch;

      final convAcc = (await _conversationAccountId(conversationId)) ??
          (me.accountId ?? '');

      final payload = <String, dynamic>{
        'conversation_id': conversationId,
        'sender_uid': uid,
        'sender_email': senderEmail,
        'kind': ChatMessageKind.file.dbValue,
        'body': null,
        'text': null,
        'created_at': now.toIso8601String(),
        'device_id': deviceId,
        'local_id': seq,
        if (clientMsgId != null && clientMsgId.isNotEmpty)
          'client_msg_id': clientMsgId,
        if (convAcc.isNotEmpty) 'account_id': convAcc,
        if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
        if (replyToSnippet != null && replyToSnippet.trim().isNotEmpty)
          'reply_to_snippet': replyToSnippet.trim(),
        if (mentionsEmails != null && mentionsEmails.isNotEmpty)
          'mentions': mentionsEmails,
      };

      Map<String, dynamic>? row;
      try {
        final data = await _runMessageMutation((fields) => '''
          mutation InsertFileMessage(\$object: ${_tblMsgs}_insert_input!) {
            insert_${_tblMsgs}(
              objects: [\$object],
              on_conflict: {
                constraint: chat_messages_conversation_client_msg_id_key,
                update_columns: [edited, edited_at]
              }
            ) {
              returning {
                $fields
              }
            }
          }
        ''', {'object': payload});
        final ret =
            (data['insert_${_tblMsgs}'] as Map?)?['returning'] as List?;
        if (ret != null && ret.isNotEmpty) {
          row = Map<String, dynamic>.from(ret.first as Map);
        }
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
        try {
          const updateMutation = '''
            mutation UpdateMessageAttachments(\$id: uuid!, \$attachments: jsonb!) {
              update_${_tblMsgs}_by_pk(
                pk_columns: {id: \$id},
                _set: {attachments: \$attachments}
              ) {
                id
              }
            }
          ''';
          await _runMutation(updateMutation, {
            'id': msg.id,
            'attachments': uploadedRows,
          });
        } catch (_) {}
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
              attachmentType: ChatAttachmentType.file,
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
        snippet: _buildSnippet(kind: ChatMessageKind.file),
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
    final data = await _runMessageQuery((fields) => '''
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
          $fields
        }
      }
    ''', {
      'cid': conversationId,
      'pattern': pattern,
      'limit': limit,
    });
    final rows = await _hydrateMessageAttachments(_rowsFromData(data, _tblMsgs));
    return await _messagesFromRows(rows);
  }

  // --------------------------------------------------------------
  // Read state
  // --------------------------------------------------------------
  Future<void> _upsertReadState({
    required String conversationId,
    String? lastDeliveredMessageId,
    DateTime? lastDeliveredAt,
    String? lastReadMessageId,
    DateTime? lastReadAt,
  }) async {
    final uid = currentUserId;
    if (uid == null || conversationId.isEmpty) return;

    final payload = <String, dynamic>{
      'conversation_id': conversationId,
      'user_uid': uid,
      if (lastDeliveredMessageId != null && lastDeliveredMessageId.isNotEmpty)
        'last_delivered_message_id': lastDeliveredMessageId,
      if (lastDeliveredAt != null)
        'last_delivered_at': lastDeliveredAt.toUtc().toIso8601String(),
      if (lastReadMessageId != null && lastReadMessageId.isNotEmpty)
        'last_read_message_id': lastReadMessageId,
      if (lastReadAt != null)
        'last_read_at': lastReadAt.toUtc().toIso8601String(),
    };

    final mutation = '''
      mutation UpsertReadState(\$object: ${_tblReads}_insert_input!) {
        insert_${_tblReads}(
          objects: [\$object],
          on_conflict: {
            constraint: chat_reads_pkey,
            update_columns: [
              last_delivered_message_id,
              last_delivered_at,
              last_read_message_id,
              last_read_at
            ]
          }
        ) {
          affected_rows
        }
      }
    ''';
    try {
      await _runMutation(mutation, {'object': payload});
    } catch (_) {}
  }

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

    await _upsertReadState(
      conversationId: conversationId,
      lastDeliveredMessageId: lastRow['id'].toString(),
      lastDeliveredAt: lastCreated,
      lastReadMessageId: lastRow['id'].toString(),
      lastReadAt: lastCreated,
    );

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
