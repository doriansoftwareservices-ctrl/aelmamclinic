// lib/models/chat_reaction.dart
//
// نموذج "تفاعل" رسالة الدردشة (Reaction) — مناسب لجدول محتمل باسم:
//   public.chat_reactions
//
// تصميم مقترح لحقل الجدول (سنضيف SQL لاحقًا):
// - id          : uuid (PK, default gen_random_uuid())
// - message_id  : uuid (NOT NULL)
// - user_uid    : uuid (NOT NULL)
// - user_email  : text (NULL)  // للعرض فقط
// - emoji       : text (NOT NULL)  // رمز واحد أو تجميعة وجوه
// - created_at  : timestamptz (NOT NULL, default now())
// - UNIQUE(message_id, user_uid, emoji) لمنع تكرار نفس التفاعل من نفس المستخدم.
//
// النموذج يدعم camelCase و snake_case عند التحويل من/إلى Map.
// يعتمد على: utils/time.dart
//

library chat_reaction_model;

import 'package:aelmamclinic/utils/time.dart' as t;

class ChatReaction {
  // -------- الحقول المخزّنة --------
  final String? id; // قد تكون null قبل الإدراج
  final String messageId;
  final String userUid;
  final String? userEmail; // اختياري للعرض
  final String emoji; // رمز/تجميعة
  final DateTime? createdAt; // UTC

  const ChatReaction({
    this.id,
    required this.messageId,
    required this.userUid,
    this.userEmail,
    required this.emoji,
    this.createdAt,
  });

  // ---------- Helpers للتحويل ----------
  static String _trimOr(String? s, String fallback) {
    final v = (s ?? '').trim();
    return v.isEmpty ? fallback : v;
  }

  static String? _trimOrNull(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  // ---------- الإنشاء من Map/JSON ----------
  /// يدعم camelCase و snake_case.
  factory ChatReaction.fromMap(Map<String, dynamic> map) {
    dynamic getKey(List<String> keys) {
      for (final k in keys) {
        if (map.containsKey(k)) return map[k];
      }
      return null;
    }

    final id = _trimOrNull(getKey(const ['id']));
    final messageId =
        _trimOr(getKey(const ['message_id', 'messageId'])?.toString(), '');
    final userUid =
        _trimOr(getKey(const ['user_uid', 'userUid'])?.toString(), '');
    final userEmail = _trimOrNull(getKey(const ['user_email', 'userEmail']));
    final emoji = _trimOr(getKey(const ['emoji'])?.toString(), '');
    final createdAt =
        t.parseDateFlexibleUtc(getKey(const ['created_at', 'createdAt']));

    return ChatReaction(
      id: id,
      messageId: messageId,
      userUid: userUid,
      userEmail: userEmail,
      emoji: emoji,
      createdAt: createdAt,
    );
  }

  factory ChatReaction.fromJson(Map<String, dynamic> json) =>
      ChatReaction.fromMap(json);

  Map<String, dynamic> toJson() => {
        'id': id,
        'messageId': messageId,
        'userUid': userUid,
        'userEmail': userEmail,
        'emoji': emoji,
        'createdAt': t.toIsoUtc(createdAt),
      };

  /// خريطة للإدراج على Remote (snake_case).
  Map<String, dynamic> toRemoteInsertMap() => {
        if (id != null) 'id': id,
        'message_id': messageId,
        'user_uid': userUid,
        if (userEmail != null) 'user_email': userEmail,
        'emoji': emoji,
        if (createdAt != null) 'created_at': t.toIsoUtc(createdAt),
      };

  /// غالبًا لا نُحدّث التفاعل بعد إنشائه (إما يُحذف لإلغاء التفاعل).
  /// لكنها متاحة لو أردت تحديث user_email مثلًا.
  Map<String, dynamic> toRemoteUpdateMap() => {
        if (userEmail != null) 'user_email': userEmail,
      };

  ChatReaction copyWith({
    String? id,
    String? messageId,
    String? userUid,
    String? userEmail,
    String? emoji,
    DateTime? createdAt,
  }) {
    return ChatReaction(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      userUid: userUid ?? this.userUid,
      userEmail: userEmail ?? this.userEmail,
      emoji: emoji ?? this.emoji,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  // ---------- Helpers للواجهة ----------

  /// هل هذا التفاعل يعود لي؟
  bool isMine(String myUid) => myUid.trim().isNotEmpty && myUid == userUid;

  /// دمج/عدّ التفاعلات حسب الإيموجي.
  static Map<String, int> countByEmoji(Iterable<ChatReaction> reactions) {
    final out = <String, int>{};
    for (final r in reactions) {
      if (r.emoji.trim().isEmpty) continue;
      out[r.emoji] = (out[r.emoji] ?? 0) + 1;
    }
    return out;
  }

  /// يعيد قائمة الإيموجيات التي ضغطها مستخدم معيّن.
  static List<String> emojisByUser(
    Iterable<ChatReaction> reactions, {
    required String userUid,
  }) {
    final uid = userUid.trim();
    if (uid.isEmpty) return const [];
    return reactions
        .where((r) => r.userUid == uid && r.emoji.trim().isNotEmpty)
        .map((r) => r.emoji)
        .toList(growable: false);
  }

  @override
  String toString() =>
      'ChatReaction(id=$id, msg=$messageId, user=$userUid, emoji=$emoji, at=$createdAt)';

  @override
  bool operator ==(Object other) {
    return other is ChatReaction &&
        other.id == id &&
        other.messageId == messageId &&
        other.userUid == userUid &&
        other.userEmail == userEmail &&
        other.emoji == emoji &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode =>
      (id ?? '').hashCode ^
      messageId.hashCode ^
      userUid.hashCode ^
      (userEmail ?? '').hashCode ^
      emoji.hashCode ^
      (createdAt?.hashCode ?? 0);
}
