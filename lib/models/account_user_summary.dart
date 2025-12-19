// lib/models/account_user_summary.dart
// ملخّص خفيف لحسابات الموظفين مع البريد والحالة.

class AccountUserSummary {
  final String userUid;
  final String email;
  final bool disabled;

  const AccountUserSummary({
    required this.userUid,
    required this.email,
    required this.disabled,
  });

  factory AccountUserSummary.fromMap(Map<String, dynamic> map) {
    final uid =
        (map['user_uid'] ?? map['uid'] ?? map['userUid'])?.toString() ?? '';
    final email =
        (map['email'] ?? map['user_email'] ?? map['mail'])?.toString() ?? '';
    final disabledValue = map['disabled'];
    final disabled = disabledValue is bool
        ? disabledValue
        : disabledValue is num
            ? disabledValue != 0
            : disabledValue?.toString().toLowerCase() == 'true';
    return AccountUserSummary(
      userUid: uid,
      email: email,
      disabled: disabled,
    );
  }

  Map<String, dynamic> toMap() => {
        'user_uid': userUid,
        'email': email,
        'disabled': disabled,
      };

  AccountUserSummary copyWith({
    String? userUid,
    String? email,
    bool? disabled,
  }) {
    return AccountUserSummary(
      userUid: userUid ?? this.userUid,
      email: email ?? this.email,
      disabled: disabled ?? this.disabled,
    );
  }
}
