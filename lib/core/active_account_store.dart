import 'package:shared_preferences/shared_preferences.dart';

/// Centralized storage for the active account context.
class ActiveAccountStore {
  ActiveAccountStore._();

  static const String accountIdKey = 'auth.accountId';

  static Future<String?> readAccountId() async {
    final sp = await SharedPreferences.getInstance();
    final value = sp.getString(accountIdKey);
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  static Future<void> writeAccountId(String? accountId) async {
    final sp = await SharedPreferences.getInstance();
    final trimmed = accountId?.trim() ?? '';
    if (trimmed.isEmpty) {
      await sp.remove(accountIdKey);
      return;
    }
    await sp.setString(accountIdKey, trimmed);
  }

  static Future<void> clearAccountId() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(accountIdKey);
  }
}
