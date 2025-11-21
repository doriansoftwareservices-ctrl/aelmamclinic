// lib/core/constants.dart
import 'package:flutter/foundation.dart';
import 'constants_supabase_override_loader_stub.dart'
    if (dart.library.io) 'constants_supabase_override_loader_io.dart'
    as override_loader;

class AppConstants {
  AppConstants._();

  static const String appName = 'Elmam Clinic';

  // -------------------- Supabase --------------------
  static const String _envSupabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );
  static const String _envSupabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  static String? _overrideSupabaseUrl;
  static String? _overrideSupabaseAnonKey;
  static List<String> _superAdminEmails = const ['admin@elmam.com'];
  static bool _overridesLoaded = false;

  static String get supabaseUrl {
    final override = _overrideSupabaseUrl?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return _requireEnv(_envSupabaseUrl, 'SUPABASE_URL');
  }

  static String get supabaseAnonKey {
    final override = _overrideSupabaseAnonKey?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }
    return _requireEnv(_envSupabaseAnonKey, 'SUPABASE_ANON_KEY');
  }

  static List<String> get superAdminEmails => _superAdminEmails;

  /// Loads runtime overrides for Supabase configuration from the platform
  /// data directory (e.g. `C:\aelmam_clinic\config.json` on Windows).
  ///
  /// The JSON file supports the keys `supabaseUrl` and `supabaseAnonKey`.
  /// Values in this file take precedence over the compile-time defaults but
  /// are still superseded by `--dart-define` values when provided.
  static Future<void> loadRuntimeOverrides() async {
    if (_overridesLoaded) {
      return;
    }
    _overridesLoaded = true;

    if (kIsWeb) {
      return;
    }

    final result = await override_loader.loadSupabaseRuntimeOverrides(
      windowsDataDir: windowsDataDir,
      legacyWindowsDataDir: legacyWindowsDataDir,
      linuxDataDir: linuxDataDir,
      macOsDataDir: macOsDataDir,
      androidDataDir: androidDataDir,
      iosLogicalDataDir: iosLogicalDataDir,
    );

    if (result == null) {
      return;
    }

    final (
      supabaseUrl: url,
      supabaseAnonKey: anonKey,
      superAdminEmails: admins,
      source: source,
    ) = result;

    if (url != null && url.isNotEmpty) {
      _overrideSupabaseUrl = url;
    }
    if (anonKey != null && anonKey.isNotEmpty) {
      _overrideSupabaseAnonKey = anonKey;
    }
    if (admins != null && admins.isNotEmpty) {
      _superAdminEmails =
          admins.map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
    }

    if (source != null && source.isNotEmpty) {
      debugLog(
        'Loaded Supabase config overrides from $source',
        tag: 'CONFIG',
      );
    }
  }

  // -------------------- مخازن محلية --------------------
  static const String windowsDataDir = r'C:\aelmam_clinic';
  static const String legacyWindowsDataDir = r'D:\aelmam_clinic';
  static const String linuxDataDir = r'~/.aelmam_clinic';
  static const String macOsDataDir =
      r'~/Library/Application Support/aelmam_clinic';
  static const String androidDataDir =
      r'/sdcard/Android/data/com.aelmam.clinic/files';
  static const String iosLogicalDataDir = r'Documents';

  static const String attachmentsSubdir = 'attachments';

  // -------------------- مزامنة --------------------
  static const bool syncInitialPull = true;
  static const bool syncRealtime = true;
  static const Duration syncPushDebounce = Duration(seconds: 1);

  // -------------------- دردشة/تخزين --------------------
  static const String chatBucketName = 'chat-attachments';
  static const int storageSignedUrlTTLSeconds = 60 * 60; // 1 ساعة
  static const int chatPageSize = 30;

  static const String tableChatConversations = 'chat_conversations';
  static const String tableChatParticipants = 'chat_participants';
  static const String tableChatMessages = 'chat_messages';
  static const String tableChatReads = 'chat_reads';
  static const String tableChatAttachments = 'chat_attachments';
  static const String tableClinics = 'clinics';
  static const String tableAccountUsers = 'account_users';

  static const bool chatPreferPublicUrls = false;
  static const int? chatMaxAttachmentBytes =
      20 * 1024 * 1024; // 20 MB إجمالي (null لإلغاء القيود)
  static const int? chatMaxSingleAttachmentBytes =
      10 * 1024 * 1024; // 10 MB لكل ملف (null لإلغاء القيود)

  // -------------------- أقسام UI --------------------
  static const String secBackup = 'نسخ احتياطي وإستعادة البيانات';

  // -------------------- Debug --------------------
  static void debugLog(Object msg, {String tag = 'APP'}) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[$tag] $msg');
    }
  }

  static String _requireEnv(String value, String key) {
    if (value.isNotEmpty) return value;
    final msg =
        'Missing $key. Provide it via --dart-define or secure environment variables.';
    if (kDebugMode) {
      // ignore: avoid_print
      print('[APP] $msg');
    }
    throw StateError(msg);
  }
}
