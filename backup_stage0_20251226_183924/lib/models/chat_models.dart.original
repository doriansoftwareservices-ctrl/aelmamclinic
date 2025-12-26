// lib/models/chat_models.dart
//
// نماذج الدردشة لمشروع ELMAM CLINIC.
// متوافقة مع الواجهات والـ Provider الحاليين.
// - تدعم أنواع المحادثات: direct / group / announcement.
// - حقول آخر رسالة: lastMsgAt / lastMsgSnippet (+ lastMessageAt/Text توافقًا).
// - حالة الرسالة: ChatMessageStatus (sending/sent/delivered/read/failed).
// - مرفقات (صور/ملفات) مع دعم url أو bucket/path + signedUrl.
// - منشئات تفاؤلية للرسائل + toMapForInsert.
// - دعم triplet (account_id/device_id/local_id) دون كسر التوافق.
// - ✅ دعم reply_to_message_id و mentions.
// - ✅ إصلاح أولوية نص الرسالة (body أولًا ثم text) ليدعم التعديل.
// - ✅ إضافة ConversationListItem لقوائم المحادثات (overview).
//
// ملاحظات:
// - تواريخ بصيغة ISO-8601 UTC عند الإرسال.
// - fromMap مرن ويدعم مفاتيح متعددة لنفس المعنى (توافقًا مع مخططات مختلفة).

import 'dart:convert';
import 'dart:io' show File;
import 'dart:math';

/// ─────────── Helpers للوقت والبريد ───────────

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v.toUtc();
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  try {
    return DateTime.parse(s).toUtc();
  } catch (_) {
    return null;
  }
}

String? _fmtDate(DateTime? dt) => dt?.toUtc().toIso8601String();
String _lc(String s) => s.trim().toLowerCase();

String _randId({String prefix = 'local'}) {
  final r = Random();
  final n = r.nextInt(1 << 32);
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}-$n';
}

int? _toInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString());
}

bool _isTruthy(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = v.toString().toLowerCase();
  return s == 'true' || s == 't' || s == '1';
}

/// ─────────── Conversation Type ───────────

enum ChatConversationType { direct, group, announcement }

extension ChatConversationTypeX on ChatConversationType {
  String get dbValue {
    switch (this) {
      case ChatConversationType.direct:
        return 'direct';
      case ChatConversationType.group:
        return 'group';
      case ChatConversationType.announcement:
        return 'announcement';
    }
  }

  static ChatConversationType fromDb(String? s, {bool? isGroupFlag}) {
    final t = (s ?? '').toLowerCase();
    if (t.isNotEmpty) {
      switch (t) {
        case 'group':
          return ChatConversationType.group;
        case 'announcement':
          return ChatConversationType.announcement;
        case 'direct':
        default:
          return ChatConversationType.direct;
      }
    }
    // توافق مع is_group:boolean
    if (isGroupFlag == true) return ChatConversationType.group;
    return ChatConversationType.direct;
  }
}

/// ─────────── Message Kind / Status ───────────
enum ChatMessageKind { text, image, file }

extension ChatMessageKindX on ChatMessageKind {
  String get dbValue {
    switch (this) {
      case ChatMessageKind.image:
        return 'image';
      case ChatMessageKind.file:
        return 'file';
      case ChatMessageKind.text:
        return 'text';
    }
  }

  static ChatMessageKind fromDb(String? s) {
    switch ((s ?? '').toLowerCase()) {
      case 'image':
        return ChatMessageKind.image;
      case 'file':
        return ChatMessageKind.file;
      case 'text':
      default:
        return ChatMessageKind.text;
    }
  }
}

enum ChatMessageStatus { sending, sent, delivered, read, failed }

extension ChatMessageStatusX on ChatMessageStatus {
  String get nameDb => toString().split('.').last;
  static ChatMessageStatus fromDb(String? s) {
    switch ((s ?? '').toLowerCase()) {
      case 'sending':
        return ChatMessageStatus.sending;
      case 'delivered':
        return ChatMessageStatus.delivered;
      case 'read':
        return ChatMessageStatus.read;
      case 'failed':
        return ChatMessageStatus.failed;
      case 'sent':
      default:
        return ChatMessageStatus.sent;
    }
  }
}

/// ─────────── Attachment (صور/ملفات) ───────────

enum ChatAttachmentType { image, file }

extension ChatAttachmentTypeX on ChatAttachmentType {
  String get dbValue {
    switch (this) {
      case ChatAttachmentType.file:
        return 'file';
      case ChatAttachmentType.image:
        return 'image';
    }
  }

  static ChatAttachmentType fromDb(String? s) {
    switch ((s ?? '').toLowerCase()) {
      case 'file':
        return ChatAttachmentType.file;
      case 'image':
      default:
        return ChatAttachmentType.image;
    }
  }
}

class ChatAttachment {
  final String? id; // uuid (قد يكون null قبل الحفظ)
  final ChatAttachmentType type; // image/file
  /// إما رابط مباشر/موقّع، أو نضعه لاحقًا بعد توقيع bucket/path.
  final String url;

  // دعم شكل DB
  final String? bucket;
  final String? path;
  final String? mimeType;
  final int? sizeBytes;
  final int? width;
  final int? height;
  final DateTime? createdAt;

  /// حقل اختياري لرابط موقّع يتم توليده من الـ storage_service
  final String? signedUrl;

  /// روابط/بيانات إضافية (اختياري)
  final Map<String, dynamic>? extra;

  bool get isImage => type == ChatAttachmentType.image;

  const ChatAttachment({
    required this.type,
    required this.url,
    this.id,
    this.bucket,
    this.path,
    this.mimeType,
    this.sizeBytes,
    this.width,
    this.height,
    this.createdAt,
    this.signedUrl,
    this.extra,
  });

  /// منشئ توافق قديم — يُرجع مرفقًا فارغًا (URL فارغ).
  const ChatAttachment.empty()
      : id = null,
        type = ChatAttachmentType.image,
        url = '',
        bucket = null,
        path = null,
        mimeType = null,
        sizeBytes = null,
        width = null,
        height = null,
        createdAt = null,
        signedUrl = null,
        extra = null;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'type': type.dbValue,
      'url': url,
      if (bucket != null) 'bucket': bucket,
      if (path != null) 'path': path,
      if (mimeType != null) 'mime_type': mimeType,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (createdAt != null) 'created_at': _fmtDate(createdAt),
      if (signedUrl != null) 'signed_url': signedUrl,
      if (extra != null) 'extra': extra,
    };
  }

  factory ChatAttachment.fromMap(Map<String, dynamic> map) {
    // URL مباشر أو public_url أو نركّب Placeholder من bucket/path
    String? url = map['url']?.toString();
    url ??= map['public_url']?.toString();
    if (url == null || url.isEmpty) {
      final bucket = map['bucket']?.toString();
      final path = map['path']?.toString();
      if (bucket != null && path != null) {
        url = 'storage://$bucket/$path'; // Placeholder محلي، وسيتم توقيعه لاحقًا
      } else {
        url = '';
      }
    }

    return ChatAttachment(
      id: map['id']?.toString(),
      type: ChatAttachmentTypeX.fromDb(map['type']?.toString()),
      url: url,
      bucket: map['bucket']?.toString(),
      path: map['path']?.toString(),
      mimeType: map['mime_type']?.toString(),
      sizeBytes: _toInt(map['size_bytes']),
      width: _toInt(map['width']),
      height: _toInt(map['height']),
      createdAt: _parseDate(map['created_at']),
      signedUrl: map['signed_url']?.toString(),
      extra: map['extra'] is Map<String, dynamic>
          ? (map['extra'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// ─────────── Conversation ───────────

class ChatConversation {
  final String id; // uuid
  final String? accountId; // قد تكون null ببعض السيناريوهات
  final ChatConversationType type;
  final String? title;
  final String? createdBy; // uid
  final DateTime createdAt;
  final DateTime? updatedAt;

  // حقول آخر رسالة (اختيارية)
  final DateTime? lastMsgAt; // أو last_message_at
  final String? lastMsgSnippet; // أو last_message_text
  final int? unreadCount;

  // توافق مع Provider القديم
  DateTime? get lastMessageAt => lastMsgAt;
  String? get lastMessageText => lastMsgSnippet;

  const ChatConversation({
    required this.id,
    required this.type,
    required this.createdAt,
    this.accountId,
    this.title,
    this.createdBy,
    this.updatedAt,
    this.lastMsgAt,
    this.lastMsgSnippet,
    this.unreadCount,
  });

  bool get isGroup => type == ChatConversationType.group;

  ChatConversation copyWith({
    String? id,
    String? accountId,
    ChatConversationType? type,
    String? title,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastMsgAt,
    String? lastMsgSnippet,
    int? unreadCount,
  }) {
    return ChatConversation(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      type: type ?? this.type,
      title: title ?? this.title,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastMsgAt: lastMsgAt ?? this.lastMsgAt,
      lastMsgSnippet: lastMsgSnippet ?? this.lastMsgSnippet,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'account_id': accountId,
      'type': type.dbValue,
      'title': title,
      'created_by': createdBy,
      'created_at': _fmtDate(createdAt),
      'updated_at': _fmtDate(updatedAt),
      // كلا التسميتين لدعم الواجهات القديمة/الجديدة
      'last_msg_at': _fmtDate(lastMsgAt),
      'last_msg_snippet': lastMsgSnippet,
      'last_message_at': _fmtDate(lastMsgAt),
      'last_message_text': lastMsgSnippet,
      'unread_count': unreadCount,
    };
  }

  factory ChatConversation.fromMap(Map<String, dynamic> map, {String? currentUid}) {
    final isGroupFlag = (map['is_group'] == true) ||
        (map['is_group']?.toString() == 'true') ||
        (map['is_group'] == 1);

    final type =
    ChatConversationTypeX.fromDb(map['type']?.toString(), isGroupFlag: isGroupFlag);

    return ChatConversation(
      id: map['id']?.toString() ?? '',
      accountId: map['account_id']?.toString(),
      type: type,
      title: map['title']?.toString(),
      createdBy: map['created_by']?.toString(),
      createdAt: _parseDate(map['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: _parseDate(map['updated_at']),
      lastMsgAt: _parseDate(map['last_msg_at'] ?? map['last_message_at']),
      lastMsgSnippet:
      map['last_msg_snippet']?.toString() ?? map['last_message_text']?.toString(),
      unreadCount: _toInt(map['unread_count']),
    );
  }

  String toJson() => jsonEncode(toMap());
  factory ChatConversation.fromJson(String source) =>
      ChatConversation.fromMap(jsonDecode(source));
}

/// ─────────── ConversationListItem (Overview) ───────────
/// عنصر لقائمة المحادثات: يجمع المحادثة + آخر رسالة + عنوان عرض + شارات إضافية.
/// مرن في fromMap ليتحمّل مخططات مختلفة من السيرفر.
class ConversationListItem {
  final ChatConversation conversation;
  final ChatMessage? lastMessage;
  final String displayTitle; // DM: بريد الطرف الآخر، Group: عنوان/مركّب من إيميلات
  final int unreadCount;
  final String? clinicLabel;
  final bool isMuted;
  final bool? isOnline; // DM فقط غالبًا

  const ConversationListItem({
    required this.conversation,
    required this.displayTitle,
    this.lastMessage,
    this.unreadCount = 0,
    this.clinicLabel,
    this.isMuted = false,
    this.isOnline,
  });

  ConversationListItem copyWith({
    ChatConversation? conversation,
    ChatMessage? lastMessage,
    String? displayTitle,
    int? unreadCount,
    String? clinicLabel,
    bool? isMuted,
    bool? isOnline,
  }) {
    return ConversationListItem(
      conversation: conversation ?? this.conversation,
      lastMessage: lastMessage ?? this.lastMessage,
      displayTitle: displayTitle ?? this.displayTitle,
      unreadCount: unreadCount ?? this.unreadCount,
      clinicLabel: clinicLabel ?? this.clinicLabel,
      isMuted: isMuted ?? this.isMuted,
      isOnline: isOnline ?? this.isOnline,
    );
  }

  static String _computeDisplayTitle(ChatConversation c, List<String> memberEmails) {
    final t = (c.title ?? '').trim();
    if (t.isNotEmpty) return t;
    if (c.type == ChatConversationType.direct) {
      // في DM نتوقع إيميل طرف واحد آخر
      if (memberEmails.isNotEmpty) return memberEmails.first;
      return 'محادثة';
    }
    if (c.type == ChatConversationType.group) {
      if (memberEmails.isNotEmpty) {
        final take = memberEmails.take(3).join('، ');
        return take;
      }
      return 'مجموعة';
    }
    return 'إعلان';
  }

  Map<String, dynamic> toMap() {
    return {
      'conversation': conversation.toMap(),
      if (lastMessage != null) 'last_message': lastMessage!.toMap(),
      'display_title': displayTitle,
      'unread_count': unreadCount,
      if (clinicLabel != null) 'clinic_label': clinicLabel,
      'muted': isMuted,
      if (isOnline != null) 'is_online': isOnline,
    };
  }

  factory ConversationListItem.fromMap(Map<String, dynamic> m) {
    // قد يأتي conversation مضمّنًا أو الحقول مسطّحة
    final convMap = (m['conversation'] is Map)
        ? Map<String, dynamic>.from(m['conversation'] as Map)
        : m;

    final conv = ChatConversation.fromMap(convMap);

    // last message: قد يكون map أو غير موجود
    ChatMessage? last;
    final lm = m['last_message'] ?? m['lastMessage'];
    if (lm is Map) {
      last = ChatMessage.fromMap(Map<String, dynamic>.from(lm));
    }

    // member emails إن وُجدت لأي توليف عنوان
    List<String> memberEmails = const [];
    final candidates = [
      m['member_emails'],
      m['members_emails'],
      m['participants_emails'],
      m['participants'],
      m['emails'],
      convMap['member_emails'],
      convMap['participants_emails'],
    ];
    for (final c in candidates) {
      if (c is List && c.isNotEmpty) {
        memberEmails = c
            .map((e) => e?.toString() ?? '')
            .where((e) => e.trim().isNotEmpty)
            .map(_lc)
            .toList();
        break;
      }
    }

    // display title
    final displayTitle = (m['display_title'] ??
        m['displayTitle'] ??
        _computeDisplayTitle(conv, memberEmails))
        .toString();

    // unread
    final unreadRaw = m['unread'] ?? m['unread_count'] ?? conv.unreadCount ?? 0;
    final unreadCount = (unreadRaw is num)
        ? unreadRaw.toInt()
        : int.tryParse(unreadRaw.toString()) ?? 0;

    final clinicLabel = (m['clinic_label'] ?? m['clinicLabel'])?.toString();
    final isMuted = _isTruthy(m['muted']);
    final isOnline =
    (m.containsKey('is_online') || m.containsKey('online')) ? _isTruthy(m['is_online'] ?? m['online']) : null;

    return ConversationListItem(
      conversation: conv,
      lastMessage: last,
      displayTitle: displayTitle,
      unreadCount: unreadCount,
      clinicLabel: (clinicLabel ?? '').trim().isEmpty ? null : clinicLabel!.trim(),
      isMuted: isMuted,
      isOnline: isOnline,
    );
  }

  String toJson() => jsonEncode(toMap());
  factory ConversationListItem.fromJson(String source) =>
      ConversationListItem.fromMap(jsonDecode(source));
}

/// ─────────── Message ───────────

class ChatMessage {
  final String id; // uuid أو local-*
  final String conversationId; // uuid
  final String senderUid; // uid
  final String? senderEmail; // اختياري
  final ChatMessageKind kind; // text / image / file
  final String? body; // نص
  final List<ChatAttachment> attachments;
  final bool edited;
  final bool deleted;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;

  // حالة/سياق واجهة
  final ChatMessageStatus status;

  /// معرّف تفاؤلي نصّي (للتطابق بين المحلي/السحابة)
  final String? localId;

  /// دعم الردّ: id + مقتطف
  final String? replyToMessageId;
  final String? replyToSnippet;

  /// المنشن (إيميلات) — اختيارية
  final List<String>? mentions;

  /// حقول DB الثلاثية (اختيارية الآن؛ ستصبح أساسية بعد الهجرات)
  final String? accountId; // uuid
  final String? deviceId; // text
  final int? localSeq; // BIGINT: عمود DB local_id (غير localId النصّي أعلاه)

  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderUid,
    required this.kind,
    required this.createdAt,
    this.senderEmail,
    this.body,
    this.attachments = const [],
    this.edited = false,
    this.deleted = false,
    this.editedAt,
    this.deletedAt,
    this.status = ChatMessageStatus.sent,
    this.localId,
    this.replyToMessageId,
    this.replyToSnippet,
    this.mentions,
    this.accountId,
    this.deviceId,
    this.localSeq,
  });

  // توافق مع الواجهات
  String get text => body ?? '';
  String? get imageUrl {
    if (attachments.isNotEmpty && attachments.first.url.isNotEmpty) {
      return attachments.first.url;
    }
    return null;
  }

  bool get hasText => (body?.trim().isNotEmpty ?? false);
  bool get hasAttachments => attachments.isNotEmpty;
  bool get hasReply => (replyToMessageId != null && replyToMessageId!.isNotEmpty);

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? senderUid,
    String? senderEmail,
    ChatMessageKind? kind,
    String? body,
    List<ChatAttachment>? attachments,
    bool? edited,
    bool? deleted,
    DateTime? createdAt,
    DateTime? editedAt,
    DateTime? deletedAt,
    ChatMessageStatus? status,
    String? localId,
    String? replyToMessageId,
    String? replyToSnippet,
    List<String>? mentions,
    String? accountId,
    String? deviceId,
    int? localSeq,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderUid: senderUid ?? this.senderUid,
      senderEmail: senderEmail ?? this.senderEmail,
      kind: kind ?? this.kind,
      body: body ?? this.body,
      attachments: attachments ?? this.attachments,
      edited: edited ?? this.edited,
      deleted: deleted ?? this.deleted,
      createdAt: createdAt ?? this.createdAt,
      editedAt: editedAt ?? this.editedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      status: status ?? this.status,
      localId: localId ?? this.localId,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToSnippet: replyToSnippet ?? this.replyToSnippet,
      mentions: mentions ?? this.mentions,
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      localSeq: localSeq ?? this.localSeq,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'sender_uid': senderUid,
      if (senderEmail != null) 'sender_email': _lc(senderEmail!),
      'kind': kind.dbValue,
      'text': body, // نخزن كذلك تحت 'text' لتوافق الواجهات القديمة
      'body': body, // الحقل المُعتمد بعد التعديل
      'edited': edited,
      'deleted': deleted,
      'created_at': _fmtDate(createdAt),
      'edited_at': _fmtDate(editedAt),
      'deleted_at': _fmtDate(deletedAt),
      if (attachments.isNotEmpty) 'attachments': attachments.map((e) => e.toMap()).toList(),
      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (replyToSnippet != null) 'reply_to_snippet': replyToSnippet,
      if (mentions != null) 'mentions': mentions!.map(_lc).toList(),

      // حالة الواجهة (اختياري تخزينها)
      'status': status.nameDb,

      // حقول DB الاختيارية:
      if (accountId != null) 'account_id': accountId,
      if (deviceId != null) 'device_id': deviceId,
      if (localSeq != null) 'local_id': localSeq,

      // الحقل المحلي التفاؤلي لديك:
      if (localId != null) 'local_id_client': localId,
    };
  }

  /// خريطة مناسبة للإدراج في جدول الرسائل.
  /// تُرسل فقط ما يحتاجه الإدراج؛ الحقول الاختيارية تُزال تلقائيًا إذا كانت null.
  Map<String, dynamic> toMapForInsert() {
    final map = <String, dynamic>{
      'conversation_id': conversationId,
      'sender_uid': senderUid,
      if (senderEmail != null) 'sender_email': _lc(senderEmail!),
      'kind': kind.dbValue,
      'body': body ?? '', // ✅ body أولًا
      'text': body ?? '', // إبقاء text للتوافق إن لزم
      'created_at': _fmtDate(createdAt),

      if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
      if (replyToSnippet != null) 'reply_to_snippet': replyToSnippet,
      if (mentions != null) 'mentions': mentions!.map(_lc).toList(),

      // عند توفر triplet
      if (accountId != null) 'account_id': accountId,
      if (deviceId != null) 'device_id': deviceId,
      if (localSeq != null) 'local_id': localSeq,

      // تمرير الـ attachments كـ payload لفنكشن إدراج مركّبة إن وُجدت
      if (attachments.isNotEmpty) 'attachments': attachments.map((e) => e.toMap()).toList(),
    };

    map.removeWhere((k, v) => v == null);
    return map;
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map, {String? currentUid}) {
    // المرفقات
    List<ChatAttachment> atts = const [];
    final rawAtt = map['attachments'];
    if (rawAtt is List) {
      atts =
          rawAtt.whereType<Map<String, dynamic>>().map(ChatAttachment.fromMap).toList();
    } else if (map['image_url'] != null) {
      // توافق مع حقل image_url المفرد
      atts = [
        ChatAttachment(type: ChatAttachmentType.image, url: map['image_url'].toString()),
      ];
    }

    final senderUid = map['sender_uid']?.toString() ?? '';

    // حالة واجهة: من DB أو اشتقاق بسيط
    ChatMessageStatus status;
    final statusRaw = map['status']?.toString();
    if (statusRaw != null && statusRaw.isNotEmpty) {
      status = ChatMessageStatusX.fromDb(statusRaw);
    } else if (_isTruthy(map['failed']) || map['error'] != null) {
      status = ChatMessageStatus.failed;
    } else if (map['read_at'] != null || _isTruthy(map['read'])) {
      status = ChatMessageStatus.read;
    } else if (map['delivered_at'] != null || _isTruthy(map['delivered'])) {
      status = ChatMessageStatus.delivered;
    } else if (map['sent_at'] != null || _isTruthy(map['sent'])) {
      status = ChatMessageStatus.sent;
    } else {
      // افتراضي معقول
      status = ((currentUid ?? '').isNotEmpty && senderUid == currentUid)
          ? ChatMessageStatus.sent
          : ChatMessageStatus.delivered;
    }

    // ✅ النص: نعطي أولوية لـ body (لأن التعديل يحدث على body)
    final body = (map['body'] ?? map['text'])?.toString();

    // نوع الرسالة (إن لم يأتِ، فحسب المرفقات)
    final kindRaw = map['kind']?.toString();
    final ChatMessageKind kind = (kindRaw == null || kindRaw.trim().isEmpty)
        ? (atts.isNotEmpty ? ChatMessageKind.image : ChatMessageKind.text)
        : ChatMessageKindX.fromDb(kindRaw);

    // local_id قد يكون BIGINT (DB) أو local-id نصّي محلي
    final localIdClient = map['local_id_client']?.toString(); // إن أعدناه من الكلاينت
    final localIdStr =
    map['local_id'] != null && map['local_id'] is String ? map['local_id'] as String : null;
    final localSeq = _toInt(map['local_id']); // BIGINT في DB

    // mentions (اختياري)
    List<String>? mentions;
    if (map['mentions'] is List) {
      mentions = (map['mentions'] as List)
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .map(_lc)
          .toList();
      if (mentions.isEmpty) mentions = null;
    }

    return ChatMessage(
      id: map['id']?.toString() ?? _randId(prefix: 'temp'),
      conversationId: map['conversation_id']?.toString() ?? '',
      senderUid: senderUid,
      senderEmail: map['sender_email']?.toString(),
      kind: kind,
      body: body,
      attachments: atts,
      edited: _isTruthy(map['edited']),
      deleted: _isTruthy(map['deleted']),
      createdAt: _parseDate(map['created_at']) ?? DateTime.now().toUtc(),
      editedAt: _parseDate(map['edited_at']),
      deletedAt: _parseDate(map['deleted_at']),
      status: status,
      localId: localIdClient ?? localIdStr, // نعيد أي قيمة نصية كما هي
      replyToMessageId: map['reply_to_message_id']?.toString(),
      replyToSnippet: map['reply_to_snippet']?.toString(),
      mentions: mentions,

      // triplet
      accountId: map['account_id']?.toString(),
      deviceId: map['device_id']?.toString(),
      localSeq: localSeq,
    );
  }

  String toJson() => jsonEncode(toMap());
  factory ChatMessage.fromJson(String source, {String? currentUid}) =>
      ChatMessage.fromMap(jsonDecode(source), currentUid: currentUid);

  /// منشئ تفاؤلي لرسالة نصية
  static ChatMessage optimisticText({
    required String conversationId,
    required String senderUid,
    required String text,
    String? senderEmail,
    String? accountId,
    String? deviceId,
    int? localSeq,
    String? replyToMessageId,
    String? replyToSnippet,
    List<String>? mentions,
  }) {
    final id = _randId(prefix: 'local');
    return ChatMessage(
      id: id,
      localId: id, // المفتاح النصّي المحلي للاقتران
      conversationId: conversationId,
      senderUid: senderUid,
      senderEmail: senderEmail,
      kind: ChatMessageKind.text,
      body: text,
      createdAt: DateTime.now().toUtc(),
      status: ChatMessageStatus.sending,
      // reply/mentions
      replyToMessageId: replyToMessageId,
      replyToSnippet: replyToSnippet,
      mentions: mentions?.map(_lc).toList(),
      // triplet (اختياري)
      accountId: accountId,
      deviceId: deviceId,
      localSeq: localSeq,
    );
  }

  /// منشئ تفاؤلي لرسالة صور/ملفات (يمكن إبقاء المرفقات فارغة حتى رفعها)
  static ChatMessage optimisticImages({
    required String conversationId,
    required String senderUid,
    required List<File> files, // placeholder لتوليد بيانات أولية إن رغبت
    String? senderEmail,
    String? caption,
    String? accountId,
    String? deviceId,
    int? localSeq,
    String? replyToMessageId,
    String? replyToSnippet,
    List<String>? mentions,
  }) {
    final id = _randId(prefix: 'local');
    return ChatMessage(
      id: id,
      localId: id,
      conversationId: conversationId,
      senderUid: senderUid,
      senderEmail: senderEmail,
      kind: ChatMessageKind.image,
      body: (caption ?? '').trim().isEmpty ? null : caption!.trim(),
      attachments: const [], // سنملؤها بعد الرفع
      createdAt: DateTime.now().toUtc(),
      status: ChatMessageStatus.sending,
      // reply/mentions
      replyToMessageId: replyToMessageId,
      replyToSnippet: replyToSnippet,
      mentions: mentions?.map(_lc).toList(),
      // triplet
      accountId: accountId,
      deviceId: deviceId,
      localSeq: localSeq,
    );
  }
}

/// ─────────── Participant (مطلوب في ChatProvider) ───────────

class ChatParticipant {
  final String conversationId;
  final String userUid;
  final String email;
  final DateTime? joinedAt;

  const ChatParticipant({
    required this.conversationId,
    required this.userUid,
    required this.email,
    this.joinedAt,
  });

  Map<String, dynamic> toMap() => {
    'conversation_id': conversationId,
    'user_uid': userUid,
    'email': email,
    if (joinedAt != null) 'joined_at': _fmtDate(joinedAt),
  };

  factory ChatParticipant.fromMap(Map<String, dynamic> m) => ChatParticipant(
    conversationId: m['conversation_id']?.toString() ?? '',
    userUid: m['user_uid']?.toString() ?? '',
    email: (m['email']?.toString() ?? '').toLowerCase(),
    joinedAt: _parseDate(m['joined_at']),
  );
}

/// ─────────── Read State (اختياري) ───────────
class ChatReadState {
  final String conversationId;
  final String userUid;
  final String? lastReadMessageId;
  final DateTime? lastReadAt;

  const ChatReadState({
    required this.conversationId,
    required this.userUid,
    this.lastReadMessageId,
    this.lastReadAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'conversation_id': conversationId,
      'user_uid': userUid,
      'last_read_message_id': lastReadMessageId,
      'last_read_at': _fmtDate(lastReadAt),
    };
  }

  factory ChatReadState.fromMap(Map<String, dynamic> map) {
    return ChatReadState(
      conversationId: map['conversation_id']?.toString() ?? '',
      userUid: map['user_uid']?.toString() ?? '',
      lastReadMessageId: map['last_read_message_id']?.toString(),
      lastReadAt: _parseDate(map['last_read_at']),
    );
  }
}

/// DM key helper to produce a consistent identifier for direct conversations.
String dmKey(String emailA, String emailB) {
  final a = _lc(emailA);
  final b = _lc(emailB);
  return (a.compareTo(b) <= 0) ? '$a|$b' : '$b|$a';
}
