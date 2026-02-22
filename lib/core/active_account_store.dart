import 'package:shared_preferences/shared_preferences.dart';

/// Centralized storage for the active account context.
class ActiveAccountStore {
  ActiveAccountStore._();

  static const String accountIdKey = 'auth.accountId';
  static const String pendingWipeKey = 'auth.pendingWipe';
  static const String pendingWipeAccountIdKey = 'auth.pendingWipeAccountId';

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

  static Future<bool> hasPendingWipe() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(pendingWipeKey) ?? false;
  }

  static Future<String?> readPendingWipeAccountId() async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getString(pendingWipeAccountIdKey);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  static Future<void> setPendingWipe(String accountId) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(pendingWipeKey, true);
    await sp.setString(pendingWipeAccountIdKey, accountId.trim());
  }

  static Future<void> clearPendingWipe() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(pendingWipeKey);
    await sp.remove(pendingWipeAccountIdKey);
  }
}
