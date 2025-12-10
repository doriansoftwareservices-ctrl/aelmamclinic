// lib/models/chat_conversation_record.dart
//
// سجل محادثة متوافق مع جدول Supabase: public.chat_conversations
// ملاحظة: هذا "سجل" DB. نموذج الواجهة ChatConversation موجود في chat_models.dart.

import 'package:aelmamclinic/utils/time.dart' as t;
import 'chat_models.dart' show ChatConversationType;

class ChatConversationRecord {
  final String id;
  final String? accountId;
  final bool isGroup;
  final String? title;
  final String createdBy;
  final DateTime createdAt; // UTC
  final DateTime updatedAt; // UTC
  final DateTime? lastMsgAt; // UTC
  final String? lastMessageText;

  // واجهة/محلي (غير محفوظ)
  final int? unreadCount;
  final String? otherEmail;
  final bool isAnnouncement;

  ChatConversationType get type => isAnnouncement
      ? ChatConversationType.announcement
      : (isGroup ? ChatConversationType.group : ChatConversationType.direct);

  String? get lastMsgSnippet => lastMessageText;

  String resolvedTitle({
    String fallbackDirect = 'محادثة',
    String fallbackGroup = 'مجموعة',
    String fallbackAnnouncement = 'إعلان',
  }) {
    if ((title ?? '').trim().isNotEmpty) return title!.trim();
    if (!isGroup && (otherEmail ?? '').trim().isNotEmpty)
      return otherEmail!.trim();
    switch (type) {
      case ChatConversationType.group:
        return fallbackGroup;
      case ChatConversationType.announcement:
        return fallbackAnnouncement;
      case ChatConversationType.direct:
        return fallbackDirect;
    }
  }

  const ChatConversationRecord({
    required this.id,
    required this.accountId,
    required this.isGroup,
    required this.title,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.lastMsgAt,
    required this.lastMessageText,
    this.unreadCount,
    this.otherEmail,
    this.isAnnouncement = false,
  });

  factory ChatConversationRecord.newDirect({
    required String tempId,
    required String createdBy,
    String? accountId,
    String? otherEmail,
  }) {
    final now = DateTime.now().toUtc();
    return ChatConversationRecord(
      id: tempId,
      accountId: accountId,
      isGroup: false,
      title: null,
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
      lastMsgAt: null,
      lastMessageText: null,
      otherEmail: otherEmail,
    );
  }

  factory ChatConversationRecord.newGroup({
    required String tempId,
    required String createdBy,
    String? accountId,
    String? title,
    bool isAnnouncement = false,
  }) {
    final now = DateTime.now().toUtc();
    return ChatConversationRecord(
      id: tempId,
      accountId: accountId,
      isGroup: true,
      title: (title ?? '').trim().isEmpty ? null : title!.trim(),
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
      lastMsgAt: null,
      lastMessageText: null,
      isAnnouncement: isAnnouncement,
    );
  }

  factory ChatConversationRecord.fromMap(Map<String, dynamic> map) {
    dynamic getKey(List<String> keys) {
      for (final k in keys) {
        if (map.containsKey(k)) return map[k];
      }
      return null;
    }

    bool _toBool(dynamic v) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final s = v.trim().toLowerCase();
        return s == '1' || s == 'true' || s == 't' || s == 'yes';
      }
      return false;
    }

    final id = (getKey(const ['id']) ?? '').toString();
    final accountId = (getKey(const ['account_id', 'accountId']))?.toString();
    final isGroup = _toBool(getKey(const ['is_group', 'isGroup']));
    final title = (getKey(const ['title']))?.toString();
    final createdBy =
        (getKey(const ['created_by', 'createdBy']) ?? '').toString();

    final createdAt =
        t.parseDateFlexibleUtc(getKey(const ['created_at', 'createdAt'])) ??
            DateTime.now().toUtc();
    final updatedAt =
        t.parseDateFlexibleUtc(getKey(const ['updated_at', 'updatedAt'])) ??
            createdAt;
    final lastMsgAt =
        t.parseDateFlexibleUtc(getKey(const ['last_msg_at', 'lastMsgAt']));
    final lastMsgSnippet = (getKey(const [
      'last_msg_snippet',
      'lastMessageText',
      'last_msg_snippet_text',
    ]))?.toString();

    final unread = getKey(const ['unread', 'unread_count', 'unreadCount']);
    final unreadCount =
        (unread is num) ? unread.toInt() : int.tryParse('${unread ?? ''}');
    final otherEmail =
        (getKey(const ['other_email', 'otherEmail']))?.toString();
    final isAnnouncement =
        _toBool(getKey(const ['is_announcement', 'isAnnouncement']));

    return ChatConversationRecord(
      id: id,
      accountId: accountId,
      isGroup: isGroup,
      title: (title ?? '').trim().isNotEmpty ? title!.trim() : null,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastMsgAt: lastMsgAt,
      lastMessageText: (lastMsgSnippet ?? '').trim().isNotEmpty
          ? lastMsgSnippet!.trim()
          : null,
      unreadCount: unreadCount,
      otherEmail:
          (otherEmail ?? '').trim().isNotEmpty ? otherEmail!.trim() : null,
      isAnnouncement: isAnnouncement,
    );
  }

  Map<String, dynamic> toRemoteInsertMap() {
    return {
      'id': id,
      if (accountId != null) 'account_id': accountId,
      'is_group': isGroup,
      if (title != null && title!.trim().isNotEmpty) 'title': title!.trim(),
      'created_by': createdBy,
      'created_at': t.toIsoUtc(createdAt),
      'updated_at': t.toIsoUtc(updatedAt),
      if (lastMsgAt != null) 'last_msg_at': t.toIsoUtc(lastMsgAt),
      if (lastMessageText != null && lastMessageText!.trim().isNotEmpty)
        'last_msg_snippet': lastMessageText!.trim(),
    };
  }

  Map<String, dynamic> toRemoteUpdateMap() {
    return {
      if (title != null) 'title': title!.trim(),
      'is_group': isGroup,
      'updated_at': t.toIsoUtc(DateTime.now().toUtc()),
      if (lastMsgAt != null) 'last_msg_at': t.toIsoUtc(lastMsgAt),
      if (lastMessageText != null) 'last_msg_snippet': lastMessageText!.trim(),
    };
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'isGroup': isGroup,
        'title': title,
        'createdBy': createdBy,
        'createdAt': t.toIsoUtc(createdAt),
        'updatedAt': t.toIsoUtc(updatedAt),
        'lastMsgAt': t.toIsoUtc(lastMsgAt),
        'lastMessageText': lastMessageText,
        'unreadCount': unreadCount,
        'otherEmail': otherEmail,
        'isAnnouncement': isAnnouncement,
      };

  factory ChatConversationRecord.fromJson(Map<String, dynamic> json) =>
      ChatConversationRecord.fromMap(json);

  ChatConversationRecord copyWith({
    String? id,
    String? accountId,
    bool? isGroup,
    String? title,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastMsgAt,
    String? lastMessageText,
    int? unreadCount,
    String? otherEmail,
    bool? isAnnouncement,
  }) {
    return ChatConversationRecord(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      isGroup: isGroup ?? this.isGroup,
      title: title ?? this.title,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastMsgAt: lastMsgAt ?? this.lastMsgAt,
      lastMessageText: lastMessageText ?? this.lastMessageText,
      unreadCount: unreadCount ?? this.unreadCount,
      otherEmail: otherEmail ?? this.otherEmail,
      isAnnouncement: isAnnouncement ?? this.isAnnouncement,
    );
  }

  @override
  String toString() =>
      'ChatConversationRecord(id=$id, type=$type, title=$title, otherEmail=$otherEmail, lastMsgAt=$lastMsgAt, unread=$unreadCount)';

  @override
  bool operator ==(Object other) {
    return other is ChatConversationRecord &&
        other.id == id &&
        other.accountId == accountId &&
        other.isGroup == isGroup &&
        other.title == title &&
        other.createdBy == createdBy &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt &&
        other.lastMsgAt == lastMsgAt &&
        other.lastMessageText == lastMessageText &&
        other.unreadCount == unreadCount &&
        other.otherEmail == otherEmail &&
        other.isAnnouncement == isAnnouncement;
  }

  @override
  int get hashCode =>
      id.hashCode ^
      (accountId ?? '').hashCode ^
      isGroup.hashCode ^
      (title ?? '').hashCode ^
      createdBy.hashCode ^
      createdAt.hashCode ^
      updatedAt.hashCode ^
      (lastMsgAt?.hashCode ?? 0) ^
      (lastMessageText ?? '').hashCode ^
      (unreadCount ?? 0).hashCode ^
      (otherEmail ?? '').hashCode ^
      isAnnouncement.hashCode;
}
