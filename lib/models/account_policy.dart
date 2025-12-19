/// تمثيل الحساب الفعّال للمستخدم الحالي (مالك/موظف) مع صلاحية الكتابة.
class ActiveAccount {
  final String id;
  final String role;
  final bool canWrite;
  const ActiveAccount({
    required this.id,
    required this.role,
    required this.canWrite,
  });
}

class AccountPolicyException implements Exception {
  final String message;
  const AccountPolicyException(this.message);
  @override
  String toString() => message;
}

class AccountFrozenException extends AccountPolicyException {
  final String accountId;
  AccountFrozenException(this.accountId)
      : super('Account $accountId is frozen');
}

class AccountUserDisabledException extends AccountPolicyException {
  final String accountId;
  AccountUserDisabledException(this.accountId)
      : super('Account user $accountId is disabled');
}
