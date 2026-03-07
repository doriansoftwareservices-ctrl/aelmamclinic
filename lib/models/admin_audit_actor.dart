class AdminAuditActor {
  final String? actorUid;
  final String? actorEmail;
  final int events;
  final DateTime? lastAt;

  const AdminAuditActor({
    required this.events,
    this.actorUid,
    this.actorEmail,
    this.lastAt,
  });

  factory AdminAuditActor.fromMap(Map<String, dynamic> map) {
    int _toInt(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
    DateTime? _toDate(dynamic v) {
      final s = v?.toString();
      return s == null ? null : DateTime.tryParse(s);
    }

    return AdminAuditActor(
      actorUid: map['actor_uid']?.toString(),
      actorEmail: map['actor_email']?.toString(),
      events: _toInt(map['events']),
      lastAt: _toDate(map['last_at']),
    );
  }
}
