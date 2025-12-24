// lib/core/constants.dart
import 'package:flutter/foundation.dart';
import 'package:aelmamclinic/core/constants_nhost_override_loader_stub.dart'
    if (dart.library.io) 'package:aelmamclinic/core/constants_nhost_override_loader_io.dart'
    as override_loader;
import 'package:aelmamclinic/core/nhost_config.dart';

class AppConstants {
  AppConstants._();

  static const String appName = 'Elmam Clinic';

  // -------------------- Nhost --------------------
  static String get nhostSubdomain => NhostConfig.subdomain;
  static String get nhostRegion => NhostConfig.region;
  static String get nhostGraphqlUrl => NhostConfig.graphqlUrl;
  static String get nhostAuthUrl => NhostConfig.authUrl;
  static String get nhostStorageUrl => NhostConfig.storageUrl;
  static String get nhostFunctionsUrl => NhostConfig.functionsUrl;
  static String get nhostAdminSecret => NhostConfig.adminSecret;
  static String get nhostWebhookSecret => NhostConfig.webhookSecret;
  static String get nhostJwtSecret => NhostConfig.jwtSecret;

  static List<String> _superAdminEmails = const [];
  static bool _overridesLoaded = false;

  static List<String> get superAdminEmails => _superAdminEmails;

  /// Loads runtime overrides for Nhost configuration from the platform
  /// data directory (e.g. `C:\aelmam_clinic\config.json` on Windows).
  ///
  /// The JSON file supports the keys `nhostSubdomain`, `nhostRegion`,
  /// `nhostGraphqlUrl`, `nhostAuthUrl`, `nhostStorageUrl`, `nhostFunctionsUrl`,
  /// `nhostAdminSecret`, `nhostWebhookSecret`, `nhostJwtSecret`,
  /// and `superAdminEmails`.
  static Future<void> loadRuntimeOverrides() async {
    if (_overridesLoaded) {
      return;
    }
    _overridesLoaded = true;

    if (kIsWeb) {
      return;
    }

    final result = await (() async {
      try {
        return await override_loader.loadNhostRuntimeOverrides(
          windowsDataDir: windowsDataDir,
          legacyWindowsDataDir: legacyWindowsDataDir,
          linuxDataDir: linuxDataDir,
          macOsDataDir: macOsDataDir,
          androidDataDir: androidDataDir,
          iosLogicalDataDir: iosLogicalDataDir,
        );
      } catch (e) {
        debugLog('Failed to load runtime overrides: $e', tag: 'CONFIG');
        return null;
      }
    })();

    if (result == null) {
      debugLog('No runtime overrides found; using defaults', tag: 'CONFIG');
      return;
    }

    final ({
      List<String>? superAdminEmails,
      String? nhostSubdomain,
      String? nhostRegion,
      String? nhostGraphqlUrl,
      String? nhostAuthUrl,
      String? nhostStorageUrl,
      String? nhostFunctionsUrl,
      String? nhostAdminSecret,
      String? nhostWebhookSecret,
      String? nhostJwtSecret,
      String? source,
    }) overrides = result;

    final admins = overrides.superAdminEmails;
    final source = overrides.source;
    final nhostSubdomain = overrides.nhostSubdomain;
    final nhostRegion = overrides.nhostRegion;
    final nhostGraphqlUrl = overrides.nhostGraphqlUrl;
    final nhostAuthUrl = overrides.nhostAuthUrl;
    final nhostStorageUrl = overrides.nhostStorageUrl;
    final nhostFunctionsUrl = overrides.nhostFunctionsUrl;
    final nhostAdminSecret = overrides.nhostAdminSecret;
    final nhostWebhookSecret = overrides.nhostWebhookSecret;
    final nhostJwtSecret = overrides.nhostJwtSecret;

    if (admins != null && admins.isNotEmpty) {
      _superAdminEmails = admins
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    NhostConfig.applyOverrides(
      subdomain: nhostSubdomain,
      region: nhostRegion,
      graphqlUrl: nhostGraphqlUrl,
      authUrl: nhostAuthUrl,
      storageUrl: nhostStorageUrl,
      functionsUrl: nhostFunctionsUrl,
      adminSecret: nhostAdminSecret,
      webhookSecret: nhostWebhookSecret,
      jwtSecret: nhostJwtSecret,
    );

    if (source != null && source.isNotEmpty) {
      debugLog(
        'Loaded Nhost config overrides from $source',
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
  // ignore: unnecessary_nullable_for_final_variable_declarations
  static const int? chatMaxAttachmentBytes =
      20 * 1024 * 1024; // 20 MB إجمالي (null لإلغاء القيود)
  // ignore: unnecessary_nullable_for_final_variable_declarations
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

}
