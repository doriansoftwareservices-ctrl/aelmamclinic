class SuperAdminAccount {
  final String email;
  final String userUid;
  final DateTime? createdAt;
  final bool disabled;
  final String defaultRole;
  final List<String> allowedTabs;
  final bool hasUser;

  const SuperAdminAccount({
    required this.email,
    required this.userUid,
    required this.createdAt,
    required this.disabled,
    required this.defaultRole,
    required this.allowedTabs,
    required this.hasUser,
  });

  factory SuperAdminAccount.fromMap(Map<String, dynamic> map) {
    return SuperAdminAccount(
      email: _toStr0(map['email']),
      userUid: _toStr0(map['user_uid']),
      createdAt: _toDateN(map['created_at']),
      disabled: _toBool(map['disabled']),
      defaultRole: _toStr0(map['default_role']),
      allowedTabs: _toStrList(map['allowed_tabs']),
      hasUser: _toBool(map['has_user']),
    );
  }

  SuperAdminAccount copyWith({
    String? email,
    String? userUid,
    DateTime? createdAt,
    bool? disabled,
    String? defaultRole,
    List<String>? allowedTabs,
    bool? hasUser,
  }) {
    return SuperAdminAccount(
      email: email ?? this.email,
      userUid: userUid ?? this.userUid,
      createdAt: createdAt ?? this.createdAt,
      disabled: disabled ?? this.disabled,
      defaultRole: defaultRole ?? this.defaultRole,
      allowedTabs: allowedTabs ?? this.allowedTabs,
      hasUser: hasUser ?? this.hasUser,
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

  static List<String> _toStrList(dynamic v) {
    if (v is List) {
      return v.map((e) => e.toString()).toList();
    }
    if (v is String && v.isNotEmpty) {
      return v
          .replaceAll('{', '')
          .replaceAll('}', '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }
}
