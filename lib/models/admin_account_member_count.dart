class AdminAccountMemberCount {
  final String accountId;
  final String accountName;
  final int ownersCount;
  final int adminsCount;
  final int employeesCount;
  final int totalMembers;

  const AdminAccountMemberCount({
    required this.accountId,
    required this.accountName,
    required this.ownersCount,
    required this.adminsCount,
    required this.employeesCount,
    required this.totalMembers,
  });

  factory AdminAccountMemberCount.fromMap(Map<String, dynamic> map) {
    return AdminAccountMemberCount(
      accountId: _toStr0(map['account_id']),
      accountName: _toStr0(map['account_name']),
      ownersCount: _toInt(map['owners_count']),
      adminsCount: _toInt(map['admins_count']),
      employeesCount: _toInt(map['employees_count']),
      totalMembers: _toInt(map['total_members']),
    );
  }

  static String _toStr0(dynamic v) => v?.toString() ?? '';

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
