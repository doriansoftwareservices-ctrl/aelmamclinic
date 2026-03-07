import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nhost_dart/nhost_dart.dart';

/// Persists Nhost auth tokens across app restarts.
/// Uses secure storage on native platforms, and falls back to memory on web.
class PersistentAuthStore implements AuthStore {
  PersistentAuthStore();

  final FlutterSecureStorage? _secure =
      kIsWeb ? null : const FlutterSecureStorage();
  final Map<String, String> _memory = <String, String>{};

  @override
  Future<String?> getString(String key) async {
    if (_secure == null) {
      return _memory[key];
    }
    return _secure!.read(key: key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (_secure == null) {
      _memory[key] = value;
      return;
    }
    await _secure!.write(key: key, value: value);
  }

  @override
  Future<void> removeItem(String key) async {
    if (_secure == null) {
      _memory.remove(key);
      return;
    }
    await _secure!.delete(key: key);
  }
}
