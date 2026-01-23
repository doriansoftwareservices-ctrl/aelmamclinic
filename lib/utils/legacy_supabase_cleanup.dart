import 'package:shared_preferences/shared_preferences.dart';

class LegacySupabaseCleanup {
  LegacySupabaseCleanup._();

  static Future<void> purge() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final toRemove = <String>{};

      for (final key in keys) {
        final lower = key.toLowerCase();
        if (lower.contains('supabase')) {
          toRemove.add(key);
          continue;
        }
        final value = prefs.get(key);
        if (value is String) {
          final valLower = value.toLowerCase();
          if (valLower.contains('supabase.co') ||
              valLower.contains('wiypiofuyrayywciovoo')) {
            toRemove.add(key);
          }
        }
      }

      for (final key in toRemove) {
        await prefs.remove(key);
      }
    } catch (_) {
      // best-effort cleanup
    }
  }
}
