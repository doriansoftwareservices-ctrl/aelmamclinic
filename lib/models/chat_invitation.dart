// lib/models/chat_invitation.dart
//
// بيانات دعوات مجموعات الدردشة (chat_group_invitations).

enum ChatGroupInvitationStatus { pending, accepted, declined, expired }

extension ChatGroupInvitationStatusX on ChatGroupInvitationStatus {
  String get dbValue {
    switch (this) {
      case ChatGroupInvitationStatus.accepted:
        return 'accepted';
      case ChatGroupInvitationStatus.declined:
        return 'declined';
      case ChatGroupInvitationStatus.expired:
        return 'expired';
      case ChatGroupInvitationStatus.pending:
      default:
        return 'pending';
    }
  }

  static ChatGroupInvitationStatus fromDb(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'accepted':
        return ChatGroupInvitationStatus.accepted;
      case 'declined':
        return ChatGroupInvitationStatus.declined;
      case 'expired':
        return ChatGroupInvitationStatus.expired;
      case 'pending':
      default:
        return ChatGroupInvitationStatus.pending;
    }
  }
}

class ChatGroupInvitation {
  final String id;
  final String conversationId;
  final String inviterUid;
  final String? inviteeUid;
  final String? inviteeEmail;
  final ChatGroupInvitationStatus status;
  final DateTime createdAt;
  final DateTime? respondedAt;
  final String? responseNote;

  // Optional conversation metadata
  final String? conversationTitle;
  final bool isGroup;
  final String? conversationAccountId;
  final String? conversationCreatedBy;

  const ChatGroupInvitation({
    required this.id,
    required this.conversationId,
    required this.inviterUid,
    this.inviteeUid,
    required this.status,
    required this.createdAt,
    this.inviteeEmail,
    this.respondedAt,
    this.responseNote,
    this.conversationTitle,
    this.isGroup = true,
    this.conversationAccountId,
    this.conversationCreatedBy,
  });

  bool get isPending => status == ChatGroupInvitationStatus.pending;
  bool get isAccepted => status == ChatGroupInvitationStatus.accepted;
  bool get isDeclined => status == ChatGroupInvitationStatus.declined;
  bool get isExpired => status == ChatGroupInvitationStatus.expired;
  bool get isActionable => status == ChatGroupInvitationStatus.pending;

  String get statusLabel {
    switch (status) {
      case ChatGroupInvitationStatus.accepted:
        return 'تم قبولها';
      case ChatGroupInvitationStatus.declined:
        return 'تم رفضها';
      case ChatGroupInvitationStatus.expired:
        return 'انتهت صلاحيتها';
      case ChatGroupInvitationStatus.pending:
      default:
        return 'قيد الانتظار';
    }
  }

  factory ChatGroupInvitation.fromMap(Map<String, dynamic> map) {
    String? _readUid(String primaryKey, String legacyKey) {
      final raw = map[primaryKey] ?? map[legacyKey];
      final val = raw?.toString().trim();
      return (val == null || val.isEmpty) ? null : val;
    }

    return ChatGroupInvitation(
      id: map['id']?.toString() ?? '',
      conversationId: map['conversation_id']?.toString() ?? '',
      inviterUid: _readUid('inviter_uid', 'inviter') ?? '',
      inviteeUid: _readUid('invitee_uid', 'invitee_user'),
      inviteeEmail: _lowerIfPresent(map['invitee_email']),
      status: ChatGroupInvitationStatusX.fromDb(map['status']?.toString()),
      createdAt: _parseDate(map['created_at']) ?? DateTime.now().toUtc(),
      respondedAt: _parseDate(map['responded_at']),
      responseNote: map['response_note']?.toString(),
      conversationTitle: map['title']?.toString(),
      isGroup: map['is_group'] == true,
      conversationAccountId: map['account_id']?.toString(),
      conversationCreatedBy: map['created_by']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'conversation_id': conversationId,
    'inviter_uid': inviterUid,
    if (inviteeUid != null) 'invitee_uid': inviteeUid,
    'invitee_email': _lowerIfPresent(inviteeEmail),
    'status': status.dbValue,
    'created_at': createdAt.toIso8601String(),
    if (respondedAt != null) 'responded_at': respondedAt!.toIso8601String(),
    if (responseNote != null && responseNote!.isNotEmpty)
      'response_note': responseNote,
    if (conversationTitle != null) 'title': conversationTitle,
    'is_group': isGroup,
    if (conversationAccountId != null) 'account_id': conversationAccountId,
    if (conversationCreatedBy != null) 'created_by': conversationCreatedBy,
  };
}

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  final raw = value.toString().trim();
  if (raw.isEmpty) return null;
  try {
    return DateTime.parse(raw).toUtc();
  } catch (_) {
    return null;
  }
}

String? _nullIfEmpty(dynamic value) {
  if (value == null) return null;
  final trimmed = value.toString().trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _lowerIfPresent(dynamic value) {
  final v = _nullIfEmpty(value);
  return v?.toLowerCase();
}
