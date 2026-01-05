class AdminAccountMember {
  final String accountId;
  final String accountName;
  final String userUid;
  final String email;
  final String role;
  final bool disabled;
  final DateTime? createdAt;

  const AdminAccountMember({
    required this.accountId,
    required this.accountName,
    required this.userUid,
    required this.email,
    required this.role,
    required this.disabled,
    required this.createdAt,
  });

  factory AdminAccountMember.fromMap(Map<String, dynamic> map) {
    return AdminAccountMember(
      accountId: _toStr0(map['account_id']),
      accountName: _toStr0(map['account_name']),
      userUid: _toStr0(map['user_uid']),
      email: _toStr0(map['email']),
      role: _toStr0(map['role']),
      disabled: _toBool(map['disabled']),
      createdAt: _toDateN(map['created_at']),
    );
  }

  static String _toStr0(dynamic v) => v?.toString() ?? '';

  static bool _toBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v?.toString().trim().toLowerCase();
    return s == 'true' || s == 't' || s == '1' || s == 'yes';
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }
}
