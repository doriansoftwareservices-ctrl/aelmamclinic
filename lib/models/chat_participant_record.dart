// lib/models/chat_participant_record.dart
//
// نموذج مشارك المحادثة المتوافق (بمرونة) مع جدول Supabase:
//   public.chat_participants
//
// نقاط مهمّة:
// - يدعم camelCase و snake_case ويقرأ أشهر الأسماء البديلة (user_id/uid…).
// - يضيف accountId اختياريًا (غالبًا موجود في جداول الحسابات متعددة المستأجرين).
// - last_read_at لا تُرسَل في التحديث إذا كانت null.
// - الحقول isTyping/isOnline/unreadCount واجهة فقط (غير محفوظة في السحابة).
//
// يعتمد على: utils/time.dart

library chat_participant_model;

import 'package:aelmamclinic/utils/time.dart' as t;

class ChatParticipantRecord {
  // -------- حقول محفوظة / محتملة في الجدول --------
  final String? id; // قد لا يوجد إن كان المفتاح مركّبًا
  final String conversationId;
  final String userUid;
  final String? accountId;

  final String? email;
  final String? displayName;
  final String? role;

  /// UTC
  final DateTime? joinedAt;
  final DateTime? lastReadAt;

  final bool muted;
  final bool pinned;
  final bool archived;
  final bool blocked;

  // -------- حقول واجهة فقط --------
  final bool isTyping;
  final bool? isOnline;
  final int? unreadCount;

  const ChatParticipantRecord({
    required this.conversationId,
    required this.userUid,
    this.id,
    this.accountId,
    this.email,
    this.displayName,
    this.role,
    this.joinedAt,
    this.lastReadAt,
    this.muted = false,
    this.pinned = false,
    this.archived = false,
    this.blocked = false,
    this.isTyping = false,
    this.isOnline,
    this.unreadCount,
  });

  // ---------- Parsing helpers ----------
  static bool _toBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == '1' || s == 'true' || s == 't' || s == 'yes';
    }
    return false;
  }

  static int? _toIntOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static String? _trimOrNull(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  /// يدعم camelCase و snake_case ويملأ ما أمكن + بدائل شائعة.
  factory ChatParticipantRecord.fromMap(Map<String, dynamic> map) {
    dynamic getKey(List<String> keys) {
      for (final k in keys) {
        if (map.containsKey(k)) return map[k];
      }
      return null;
    }

    final id = _trimOrNull(getKey(const ['id']));
    final conversationId =
        (getKey(const ['conversation_id', 'conversationId']) ?? '').toString();
    final userUid =
        (getKey(const ['user_uid', 'userUid', 'user_id', 'userId', 'uid']) ??
                '')
            .toString();

    final accountId = _trimOrNull(getKey(const ['account_id', 'accountId']));

    final rawEmail =
        _trimOrNull(getKey(const ['email', 'user_email', 'email_address']));
    final email = rawEmail?.toLowerCase();

    final displayName = _trimOrNull(
        getKey(const ['display_name', 'displayName', 'nickname', 'name']));
    final role = _trimOrNull(getKey(const ['role', 'participant_role']));

    final joinedAt =
        t.parseDateFlexibleUtc(getKey(const ['joined_at', 'joinedAt']));
    final lastReadAt =
        t.parseDateFlexibleUtc(getKey(const ['last_read_at', 'lastReadAt']));

    final muted = _toBool(getKey(const ['muted', 'is_muted', 'isMuted']));
    final pinned = _toBool(getKey(const ['pinned', 'is_pinned', 'isPinned']));
    final archived =
        _toBool(getKey(const ['archived', 'is_archived', 'isArchived']));
    final blocked =
        _toBool(getKey(const ['blocked', 'is_blocked', 'isBlocked']));

    // واجهة:
    final isTyping = _toBool(getKey(const ['isTyping', 'typing']));
    final isOnlineRaw = getKey(const ['isOnline', 'online']);
    final isOnline = (isOnlineRaw == null) ? null : _toBool(isOnlineRaw);
    final unreadCount = _toIntOrNull(getKey(const ['unread', 'unreadCount']));

    return ChatParticipantRecord(
      id: id,
      conversationId: conversationId,
      userUid: userUid,
      accountId: accountId,
      email: email,
      displayName: displayName,
      role: role,
      joinedAt: joinedAt,
      lastReadAt: lastReadAt,
      muted: muted,
      pinned: pinned,
      archived: archived,
      blocked: blocked,
      isTyping: isTyping,
      isOnline: isOnline,
      unreadCount: unreadCount,
    );
  }

  factory ChatParticipantRecord.fromJson(Map<String, dynamic> json) =>
      ChatParticipantRecord.fromMap(json);

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'userUid': userUid,
        'accountId': accountId,
        'email': email,
        'displayName': displayName,
        'role': role,
        'joinedAt': t.toIsoUtc(joinedAt),
        'lastReadAt': t.toIsoUtc(lastReadAt),
        'muted': muted,
        'pinned': pinned,
        'archived': archived,
        'blocked': blocked,
        // UI-only:
        'isTyping': isTyping,
        'isOnline': isOnline,
        'unreadCount': unreadCount,
      };

  /// خريطة إدراج إلى Supabase (snake_case). تجاهَل الحقول غير الموجودة في الجدول.
  Map<String, dynamic> toRemoteInsertMap() => {
        if (id != null) 'id': id,
        'conversation_id': conversationId,
        'user_uid': userUid,
        if (accountId != null) 'account_id': accountId,
        if (email != null) 'email': email,
        if (displayName != null) 'display_name': displayName,
        if (role != null) 'role': role,
        if (joinedAt != null) 'joined_at': t.toIsoUtc(joinedAt),
        if (lastReadAt != null) 'last_read_at': t.toIsoUtc(lastReadAt),
        'muted': muted,
        'pinned': pinned,
        'archived': archived,
        'blocked': blocked,
      };

  /// خريطة تحديث إلى Supabase (snake_case).
  Map<String, dynamic> toRemoteUpdateMap() => {
        if (email != null) 'email': email,
        if (displayName != null) 'display_name': displayName,
        if (role != null) 'role': role,
        'muted': muted,
        'pinned': pinned,
        'archived': archived,
        'blocked': blocked,
        if (lastReadAt != null) 'last_read_at': t.toIsoUtc(lastReadAt),
      };

  ChatParticipantRecord copyWith({
    String? id,
    String? conversationId,
    String? userUid,
    String? accountId,
    String? email,
    String? displayName,
    String? role,
    DateTime? joinedAt,
    DateTime? lastReadAt,
    bool? muted,
    bool? pinned,
    bool? archived,
    bool? blocked,
    bool? isTyping,
    bool? isOnline,
    int? unreadCount,
  }) {
    return ChatParticipantRecord(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      userUid: userUid ?? this.userUid,
      accountId: accountId ?? this.accountId,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      role: role ?? this.role,
      joinedAt: joinedAt ?? this.joinedAt,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      muted: muted ?? this.muted,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      blocked: blocked ?? this.blocked,
      isTyping: isTyping ?? this.isTyping,
      isOnline: isOnline ?? this.isOnline,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }

  /// تفضيل عرض عنوان مناسب في الواجهة (اسم/بريد)
  String displayLabel({bool preferName = true}) {
    final name = (displayName ?? '').trim();
    final mail = (email ?? '').trim();
    if (preferName && name.isNotEmpty) return name;
    if (mail.isNotEmpty) return mail;
    if (!preferName && name.isNotEmpty) return name;
    return 'عضو';
  }

  // ملائمة بسيطة لأدوار شائعة
  bool get isOwner => (role ?? '').toLowerCase() == 'owner';
  bool get isAdmin => (role ?? '').toLowerCase() == 'admin';

  @override
  String toString() =>
      'ChatParticipantRecord(user=$userUid, conv=$conversationId, email=$email, role=$role, muted=$muted, pinned=$pinned, unread=$unreadCount)';

  @override
  bool operator ==(Object other) {
    return other is ChatParticipantRecord &&
        other.id == id &&
        other.conversationId == conversationId &&
        other.userUid == userUid &&
        other.accountId == accountId &&
        other.email == email &&
        other.displayName == displayName &&
        other.role == role &&
        other.joinedAt == joinedAt &&
        other.lastReadAt == lastReadAt &&
        other.muted == muted &&
        other.pinned == pinned &&
        other.archived == archived &&
        other.blocked == blocked &&
        other.isTyping == isTyping &&
        other.isOnline == isOnline &&
        other.unreadCount == unreadCount;
  }

  @override
  int get hashCode =>
      (id ?? '').hashCode ^
      conversationId.hashCode ^
      userUid.hashCode ^
      (accountId ?? '').hashCode ^
      (email ?? '').hashCode ^
      (displayName ?? '').hashCode ^
      (role ?? '').hashCode ^
      (joinedAt?.hashCode ?? 0) ^
      (lastReadAt?.hashCode ?? 0) ^
      muted.hashCode ^
      pinned.hashCode ^
      archived.hashCode ^
      blocked.hashCode ^
      isTyping.hashCode ^
      (isOnline?.hashCode ?? 0) ^
      (unreadCount ?? 0).hashCode;
}
