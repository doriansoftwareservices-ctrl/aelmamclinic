class AdminUsageDaily {
  final DateTime day;
  final int messages;
  final int attachments;

  const AdminUsageDaily({
    required this.day,
    required this.messages,
    required this.attachments,
  });

  factory AdminUsageDaily.fromMap(Map<String, dynamic> map) {
    DateTime _toDate(dynamic v) {
      final s = v?.toString();
      return s == null ? DateTime.fromMillisecondsSinceEpoch(0) :
          (DateTime.tryParse(s) ?? DateTime.fromMillisecondsSinceEpoch(0));
    }
    int _toInt(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;

    return AdminUsageDaily(
      day: _toDate(map['day']),
      messages: _toInt(map['messages']),
      attachments: _toInt(map['attachments']),
    );
  }
}
