class AdminAuditActivity {
  final DateTime day;
  final String tableName;
  final String op;
  final int events;

  const AdminAuditActivity({
    required this.day,
    required this.tableName,
    required this.op,
    required this.events,
  });

  factory AdminAuditActivity.fromMap(Map<String, dynamic> map) {
    DateTime _toDate(dynamic v) {
      final s = v?.toString();
      return s == null ? DateTime.fromMillisecondsSinceEpoch(0) :
          (DateTime.tryParse(s) ?? DateTime.fromMillisecondsSinceEpoch(0));
    }
    int _toInt(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;

    return AdminAuditActivity(
      day: _toDate(map['day']),
      tableName: map['table_name']?.toString() ?? '',
      op: map['op']?.toString() ?? '',
      events: _toInt(map['events']),
    );
  }
}
