/// Shared auth role state used by services that cannot access providers.
class AuthRoleState {
  AuthRoleState._();

  static bool? _isSuperAdmin;

  static bool get isSuperAdmin => _isSuperAdmin == true;

  static void setSuperAdmin(bool? value) {
    _isSuperAdmin = value;
  }

  static void clear() {
    _isSuperAdmin = null;
  }
}
