import 'package:aelmamclinic/utils/time.dart' as t;

/// Column keys and mapping helpers for the `chat_participants` table.
class ChatParticipantFields {
  ChatParticipantFields._();

  static const String table = 'chat_participants';

  static const String accountId = 'account_id';
  static const String accountIdCamel = 'accountId';

  static const String conversationId = 'conversation_id';
  static const String conversationIdCamel = 'conversationId';

  static const String userUid = 'user_uid';
  static const String userUidCamel = 'userUid';

  static const String email = 'email';
  static const String emailCamel = 'email';

  static const String nickname = 'nickname';

  static const String displayName = 'display_name';
  static const String displayNameCamel = 'displayName';

  static const String role = 'role';
  static const String roleCamel = 'role';

  static const String joinedAt = 'joined_at';
  static const String joinedAtCamel = 'joinedAt';

  static const String lastReadAt = 'last_read_at';
  static const String lastReadAtCamel = 'lastReadAt';

  static const String muted = 'muted';
  static const String mutedCamel = 'muted';

  static const String pinned = 'pinned';
  static const String pinnedCamel = 'pinned';

  static const String archived = 'archived';
  static const String archivedCamel = 'archived';

  static const String blocked = 'blocked';
  static const String blockedCamel = 'blocked';

  /// Columns that should be selected from Supabase for a participant row.
  static const List<String> remoteColumns = <String>[
    accountId,
    conversationId,
    userUid,
    email,
    displayName,
    nickname,
    role,
    joinedAt,
    lastReadAt,
    muted,
    pinned,
    archived,
    blocked,
  ];

  /// Camel-case keys used locally inside the application.
  static const List<String> localColumns = <String>[
    accountIdCamel,
    conversationIdCamel,
    userUidCamel,
    emailCamel,
    displayNameCamel,
    roleCamel,
    joinedAtCamel,
    lastReadAtCamel,
    mutedCamel,
    pinnedCamel,
    archivedCamel,
    blockedCamel,
  ];

  static const Set<String> boolColumns = <String>{
    muted,
    pinned,
    archived,
    blocked,
  };
}

class ChatParticipantMapper {
  const ChatParticipantMapper._();

  static dynamic _first(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (map.containsKey(key)) return map[key];
    }
    return null;
  }

  static String? _trim(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static String? _lower(dynamic value) {
    final text = _trim(value);
    return text?.toLowerCase();
  }

  static bool _toBool(dynamic value, {bool fallback = false}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalised = value.trim().toLowerCase();
      if (normalised.isEmpty) return fallback;
      return normalised == '1' ||
          normalised == 'true' ||
          normalised == 't' ||
          normalised == 'yes';
    }
    return fallback;
  }

  static Map<String, Object?> toRemote(Map<String, dynamic> localRow) {
    final conversationId = _trim(_first(localRow, <String>[
      ChatParticipantFields.conversationId,
      ChatParticipantFields.conversationIdCamel
    ]));
    final userUid = _trim(_first(localRow, <String>[
      ChatParticipantFields.userUid,
      ChatParticipantFields.userUidCamel
    ]));

    if (conversationId == null || conversationId.isEmpty) {
      throw ArgumentError('chat_participants requires conversation_id');
    }
    if (userUid == null || userUid.isEmpty) {
      throw ArgumentError('chat_participants requires user_uid');
    }

    final accountId = _trim(_first(localRow, <String>[
      ChatParticipantFields.accountId,
      ChatParticipantFields.accountIdCamel
    ]));
    final email = _lower(_first(localRow, <String>[
      ChatParticipantFields.email,
      ChatParticipantFields.emailCamel
    ]));
    final displayName = _trim(_first(localRow, <String>[
      ChatParticipantFields.displayName,
      ChatParticipantFields.displayNameCamel
    ]));
    final nickname = _trim(localRow[ChatParticipantFields.nickname]);
    final role = _trim(_first(localRow,
        <String>[ChatParticipantFields.role, ChatParticipantFields.roleCamel]));

    final joinedAt = t.parseDateFlexibleUtc(_first(localRow, <String>[
      ChatParticipantFields.joinedAt,
      ChatParticipantFields.joinedAtCamel
    ]));
    final lastReadAt = t.parseDateFlexibleUtc(_first(localRow, <String>[
      ChatParticipantFields.lastReadAt,
      ChatParticipantFields.lastReadAtCamel
    ]));

    final muted = _toBool(
      _first(localRow, <String>[
        ChatParticipantFields.muted,
        ChatParticipantFields.mutedCamel
      ]),
      fallback: false,
    );
    final pinned = _toBool(
      _first(localRow, <String>[
        ChatParticipantFields.pinned,
        ChatParticipantFields.pinnedCamel
      ]),
      fallback: false,
    );
    final archived = _toBool(
      _first(localRow, <String>[
        ChatParticipantFields.archived,
        ChatParticipantFields.archivedCamel
      ]),
      fallback: false,
    );
    final blocked = _toBool(
      _first(localRow, <String>[
        ChatParticipantFields.blocked,
        ChatParticipantFields.blockedCamel
      ]),
      fallback: false,
    );

    final payload = <String, Object?>{
      ChatParticipantFields.conversationId: conversationId,
      ChatParticipantFields.userUid: userUid,
      ChatParticipantFields.muted: muted,
      ChatParticipantFields.pinned: pinned,
      ChatParticipantFields.archived: archived,
      ChatParticipantFields.blocked: blocked,
    };

    if (accountId != null) {
      payload[ChatParticipantFields.accountId] = accountId;
    }
    if (email != null) {
      payload[ChatParticipantFields.email] = email;
    }
    if (displayName != null) {
      payload[ChatParticipantFields.displayName] = displayName;
    } else if (nickname != null) {
      payload[ChatParticipantFields.nickname] = nickname;
    }
    if (role != null) {
      payload[ChatParticipantFields.role] = role;
    }
    if (joinedAt != null) {
      payload[ChatParticipantFields.joinedAt] = t.toIsoUtc(joinedAt);
    }
    if (lastReadAt != null) {
      payload[ChatParticipantFields.lastReadAt] = t.toIsoUtc(lastReadAt);
    }

    return payload;
  }

  static Map<String, dynamic> fromRemote(Map<String, dynamic> remoteRow) {
    final conversationId =
        _trim(remoteRow[ChatParticipantFields.conversationId]) ?? '';
    final userUid = _trim(remoteRow[ChatParticipantFields.userUid]) ?? '';
    final accountId = _trim(remoteRow[ChatParticipantFields.accountId]);
    final email = _lower(remoteRow[ChatParticipantFields.email]);
    final displayName = _trim(remoteRow[ChatParticipantFields.displayName]) ??
        _trim(remoteRow[ChatParticipantFields.nickname]);
    final role = _trim(remoteRow[ChatParticipantFields.role]);
    final joinedAt =
        t.parseDateFlexibleUtc(remoteRow[ChatParticipantFields.joinedAt]);
    final lastReadAt =
        t.parseDateFlexibleUtc(remoteRow[ChatParticipantFields.lastReadAt]);
    final muted = _toBool(remoteRow[ChatParticipantFields.muted]);
    final pinned = _toBool(remoteRow[ChatParticipantFields.pinned]);
    final archived = _toBool(remoteRow[ChatParticipantFields.archived]);
    final blocked = _toBool(remoteRow[ChatParticipantFields.blocked]);

    final result = <String, dynamic>{
      ChatParticipantFields.conversationIdCamel: conversationId,
      ChatParticipantFields.userUidCamel: userUid,
      ChatParticipantFields.mutedCamel: muted,
      ChatParticipantFields.pinnedCamel: pinned,
      ChatParticipantFields.archivedCamel: archived,
      ChatParticipantFields.blockedCamel: blocked,
    };

    if (accountId != null) {
      result[ChatParticipantFields.accountIdCamel] = accountId;
    }
    if (email != null) {
      result[ChatParticipantFields.emailCamel] = email;
    }
    if (displayName != null) {
      result[ChatParticipantFields.displayNameCamel] = displayName;
    }
    if (role != null) {
      result[ChatParticipantFields.roleCamel] = role;
    }
    if (joinedAt != null) {
      result[ChatParticipantFields.joinedAtCamel] = joinedAt;
    }
    if (lastReadAt != null) {
      result[ChatParticipantFields.lastReadAtCamel] = lastReadAt;
    }

    return result;
  }

  static Map<String, Object?> pinnedPatch(bool pinned) =>
      <String, Object?>{ChatParticipantFields.pinned: pinned};

  static Map<String, Object?> archivedPatch(bool archived) =>
      <String, Object?>{ChatParticipantFields.archived: archived};

  static Map<String, Object?> blockedPatch(bool blocked) =>
      <String, Object?>{ChatParticipantFields.blocked: blocked};

  static Map<String, Object?> lastReadPatch(DateTime? timestamp) {
    final ts = (timestamp ?? DateTime.now()).toUtc();
    return <String, Object?>{
      ChatParticipantFields.lastReadAt: t.toIsoUtc(ts),
    };
  }
}
