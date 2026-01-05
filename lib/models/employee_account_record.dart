class EmployeeAccountRecord {
  final String userUid;
  final String email;
  final String role;
  final bool disabled;
  final DateTime? createdAt;
  final String? employeeId;
  final String? doctorId;

  const EmployeeAccountRecord({
    required this.userUid,
    required this.email,
    required this.role,
    required this.disabled,
    this.createdAt,
    this.employeeId,
    this.doctorId,
  });

  static String _toStr0(dynamic v) => v?.toString() ?? '';
  static String? _toStrN(dynamic v) => v?.toString();

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

  factory EmployeeAccountRecord.fromMap(Map<String, dynamic> map) {
    return EmployeeAccountRecord(
      userUid: _toStr0(map['user_uid']),
      email: _toStr0(map['email']),
      role: _toStr0(map['role']).isEmpty ? 'employee' : _toStr0(map['role']),
      disabled: _toBool(map['disabled']),
      createdAt: _toDateN(map['created_at']),
      employeeId: _toStrN(map['employee_id']),
      doctorId: _toStrN(map['doctor_id']),
    );
  }
}
