// lib/models/chat_participant.dart
//
// نموذج مشارك المحادثة المتوافق (بمرونة) مع جدول Remote:
//   public.chat_participants
//
// ⚠ لا نملك مخطط الأعمدة التفصيلي لهذا الجدول من مخرجاتك؛
// لذا صُمِّم النموذج ليكون "مرنًا" ويقرأ أشهر الحقول بأسماء snake_case و camelCase.
// يمكنك استخدامه مباشرة الآن، ثم لاحقًا إن أضفت أعمدة جديدة فالغالب لن تحتاج
// لتغيير الكود لأن fromMap يبحث عن أكثر من اسم لنفس المعنى.
//
// حقول شائعة يتوقعها هذا النموذج:
// - (id)                 : uuid (اختياري؛ بعض التصاميم تجعل المفتاح مركّبًا من conversation_id + user_uid)
// - (conversation_id)    : uuid
// - (user_uid)           : uuid
// - (email)              : text (اختياري)
// - (display_name)       : text (اختياري)  // أو nickname
// - (role)               : text (member/admin/owner…)
// - (joined_at)          : timestamptz
// - (last_read_at)       : timestamptz (آخر قراءة داخل هذه المحادثة)
// - (muted)              : bool  (كتم الإشعارات)
// - (pinned)             : bool  (تثبيت المحادثة لهذا المستخدم)
// - (archived)           : bool
// - (blocked)            : bool
//
// حقول واجهة (غير محفوظة):
// - isTyping             : المستخدم يكتب الآن (للعرض اللحظي)
// - isOnline             : حالة الاتصال (إن وُجد مصدر لها)
// - unreadCount          : عدد غير مقروء لهذا المشارِك (عادةً يُحسَب من chat_reads)
//
// ملاحظات:
// - كل التواريخ تُتعامل كـ UTC عند التحليل/الإخراج.
// - عند الإدراج/التحديث على السحابة نستخدم snake_case.
// - الحقول غير الموجودة ببساطة تُترك null.
//
// يعتمد على: utils/time.dart
//

library chat_participant_model;

import 'package:aelmamclinic/utils/time.dart' as t;

class ChatParticipant {
  // -------- حقول محفوظة / محتملة في الجدول --------
  final String? id; // قد لا يوجد إن كان المفتاح مركّبًا
  final String conversationId;
  final String userUid;

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

  const ChatParticipant({
    required this.conversationId,
    required this.userUid,
    this.id,
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

  /// يدعم camelCase و snake_case ويملأ ما أمكن.
  factory ChatParticipant.fromMap(Map<String, dynamic> map) {
    dynamic getKey(List<String> keys) {
      for (final k in keys) {
        if (map.containsKey(k)) return map[k];
      }
      return null;
    }

    final id = _trimOrNull(getKey(const ['id']));
    final conversationId =
        (getKey(const ['conversation_id', 'conversationId']) ?? '').toString();
    final userUid = (getKey(const ['user_uid', 'userUid']) ?? '').toString();

    final email = _trimOrNull(getKey(const ['email']));
    final displayName =
        _trimOrNull(getKey(const ['display_name', 'displayName', 'nickname']));
    final role = _trimOrNull(getKey(const ['role']));

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

    return ChatParticipant(
      id: id,
      conversationId: conversationId,
      userUid: userUid,
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

  factory ChatParticipant.fromJson(Map<String, dynamic> json) =>
      ChatParticipant.fromMap(json);

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'userUid': userUid,
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

  /// خريطة إدراج إلى Remote (snake_case). تجاهَل الحقول غير الموجودة في الجدول.
  Map<String, dynamic> toRemoteInsertMap() => {
        if (id != null) 'id': id,
        'conversation_id': conversationId,
        'user_uid': userUid,
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

  /// خريطة تحديث إلى Remote (snake_case).
  Map<String, dynamic> toRemoteUpdateMap() => {
        if (email != null) 'email': email,
        if (displayName != null) 'display_name': displayName,
        if (role != null) 'role': role,
        'muted': muted,
        'pinned': pinned,
        'archived': archived,
        'blocked': blocked,
        'last_read_at': t.toIsoUtc(lastReadAt),
      };

  ChatParticipant copyWith({
    String? id,
    String? conversationId,
    String? userUid,
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
    return ChatParticipant(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      userUid: userUid ?? this.userUid,
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

  @override
  String toString() =>
      'ChatParticipant(user=$userUid, conv=$conversationId, email=$email, role=$role, muted=$muted, pinned=$pinned, unread=$unreadCount)';

  @override
  bool operator ==(Object other) {
    return other is ChatParticipant &&
        other.id == id &&
        other.conversationId == conversationId &&
        other.userUid == userUid &&
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
