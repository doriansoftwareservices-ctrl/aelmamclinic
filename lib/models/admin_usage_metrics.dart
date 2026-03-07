class AdminUsageMetrics {
  final int accounts;
  final int accountUsers;
  final int chatMessages30d;
  final int chatAttachments;
  final int auditEvents7d;
  final int? activeUsers30d;
  final DateTime serverTime;

  const AdminUsageMetrics({
    required this.accounts,
    required this.accountUsers,
    required this.chatMessages30d,
    required this.chatAttachments,
    required this.auditEvents7d,
    required this.serverTime,
    this.activeUsers30d,
  });

  factory AdminUsageMetrics.fromJson(Map<String, dynamic> json) {
    int _toInt(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
    DateTime _toDate(dynamic v) {
      final s = v?.toString();
      return s == null ? DateTime.now() : DateTime.tryParse(s) ?? DateTime.now();
    }

    return AdminUsageMetrics(
      accounts: _toInt(json['accounts']),
      accountUsers: _toInt(json['account_users']),
      chatMessages30d: _toInt(json['chat_messages_30d']),
      chatAttachments: _toInt(json['chat_attachments']),
      auditEvents7d: _toInt(json['audit_events_7d']),
      activeUsers30d: json['active_users_30d'] == null
          ? null
          : _toInt(json['active_users_30d']),
      serverTime: _toDate(json['server_time']),
    );
  }
}
