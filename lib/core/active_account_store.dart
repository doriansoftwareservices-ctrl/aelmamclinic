import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ActiveAccountSnapshot {
  const ActiveAccountSnapshot({
    required this.accountId,
    required this.pendingWipe,
    required this.pendingWipeAccountId,
  });

  final String? accountId;
  final bool pendingWipe;
  final String? pendingWipeAccountId;
}

/// Centralized storage for the active account context.
class ActiveAccountStore {
  ActiveAccountStore._();

  static const String accountIdKey = 'auth.accountId';
  static const String pendingWipeKey = 'auth.pendingWipe';
  static const String pendingWipeAccountIdKey = 'auth.pendingWipeAccountId';
  static ActiveAccountSnapshot? _cachedSnapshot;

  static Future<ActiveAccountSnapshot> readSnapshot({
    bool refresh = false,
  }) async {
    if (!refresh && _cachedSnapshot != null) {
      return _cachedSnapshot!;
    }
    final sp = await SharedPreferences.getInstance();
    final accountId = _normalize(sp.getString(accountIdKey));
    final pendingWipe = sp.getBool(pendingWipeKey) ?? false;
    final pendingWipeAccountId =
        _normalize(sp.getString(pendingWipeAccountIdKey));
    final snapshot = ActiveAccountSnapshot(
      accountId: accountId,
      pendingWipe: pendingWipe,
      pendingWipeAccountId: pendingWipeAccountId,
    );
    _cachedSnapshot = snapshot;
    return snapshot;
  }

  static Future<String?> readAccountId({bool allowPendingWipe = false}) async {
    final snapshot = await readSnapshot();
    if (snapshot.pendingWipe && !allowPendingWipe) {
      return null;
    }
    return snapshot.accountId;
  }

  static Future<void> writeAccountId(String? accountId) async {
    final sp = await SharedPreferences.getInstance();
    final trimmed = _normalize(accountId) ?? '';
    if (trimmed.isEmpty) {
      await sp.remove(accountIdKey);
      final current = await readSnapshot(refresh: true);
      _cachedSnapshot = ActiveAccountSnapshot(
        accountId: null,
        pendingWipe: current.pendingWipe,
        pendingWipeAccountId: current.pendingWipeAccountId,
      );
      return;
    }
    await sp.setString(accountIdKey, trimmed);
    final current = await readSnapshot(refresh: true);
    _cachedSnapshot = ActiveAccountSnapshot(
      accountId: trimmed,
      pendingWipe: current.pendingWipe,
      pendingWipeAccountId: current.pendingWipeAccountId,
    );
  }

  static Future<void> clearAccountId() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(accountIdKey);
    final current = await readSnapshot(refresh: true);
    _cachedSnapshot = ActiveAccountSnapshot(
      accountId: null,
      pendingWipe: current.pendingWipe,
      pendingWipeAccountId: current.pendingWipeAccountId,
    );
  }

  static Future<bool> hasPendingWipe() async {
    final snapshot = await readSnapshot();
    return snapshot.pendingWipe;
  }

  static Future<String?> readPendingWipeAccountId() async {
    final snapshot = await readSnapshot();
    return snapshot.pendingWipeAccountId;
  }

  static Future<void> setPendingWipe(String? accountId) async {
    final sp = await SharedPreferences.getInstance();
    final normalized = _normalize(accountId);
    await sp.setBool(pendingWipeKey, true);
    if (normalized == null) {
      await sp.remove(pendingWipeAccountIdKey);
    } else {
      await sp.setString(pendingWipeAccountIdKey, normalized);
    }
    final current = await readSnapshot(refresh: true);
    _cachedSnapshot = ActiveAccountSnapshot(
      accountId: current.accountId,
      pendingWipe: true,
      pendingWipeAccountId: normalized,
    );
  }

  static Future<void> clearPendingWipe() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(pendingWipeKey);
    await sp.remove(pendingWipeAccountIdKey);
    final current = await readSnapshot(refresh: true);
    _cachedSnapshot = ActiveAccountSnapshot(
      accountId: current.accountId,
      pendingWipe: false,
      pendingWipeAccountId: null,
    );
  }

  static String? _normalize(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  @visibleForTesting
  static void resetForTesting() {
    _cachedSnapshot = null;
  }
}
