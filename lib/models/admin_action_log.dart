class AdminActionLog {
  final String id;
  final String actorUid;
  final String? actorEmail;
  final String action;
  final String entityType;
  final String? entityId;
  final Map<String, dynamic>? details;
  final DateTime createdAt;

  const AdminActionLog({
    required this.id,
    required this.actorUid,
    required this.action,
    required this.entityType,
    required this.createdAt,
    this.actorEmail,
    this.entityId,
    this.details,
  });

  factory AdminActionLog.fromMap(Map<String, dynamic> map) {
    return AdminActionLog(
      id: map['id']?.toString() ?? '',
      actorUid: map['actor_uid']?.toString() ?? '',
      actorEmail: map['actor_email']?.toString(),
      action: map['action']?.toString() ?? '',
      entityType: map['entity_type']?.toString() ?? '',
      entityId: map['entity_id']?.toString(),
      details: map['details'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(map['details'] as Map)
          : null,
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
