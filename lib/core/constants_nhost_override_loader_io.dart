import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<
    ({
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
      String? source
    })?> loadNhostRuntimeOverrides({
  required String windowsDataDir,
  required String legacyWindowsDataDir,
  required String linuxDataDir,
  required String macOsDataDir,
  required String androidDataDir,
  required String iosLogicalDataDir,
}) async {
  final candidatePaths = <String>{};

  String? normalize(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  void addFile(String? path) {
    final normalized = normalize(path);
    if (normalized != null) {
      candidatePaths.add(normalized);
    }
  }

  void addDirConfig(String? dir, {bool expandHome = false}) {
    final base = dir == null ? null : (expandHome ? expandHomeDir(dir) : dir);
    addFile(base == null ? null : p.join(base, 'config.json'));
  }

  Map<String, String>? env;
  try {
    env = Platform.environment;
  } catch (_) {
    env = null;
  }

  if (env != null) {
    addFile(env['AELMAM_CONFIG'] ?? env['AELMAM_CLINIC_CONFIG']);
    addFile(env['AELMAM_NHOST_CONFIG']);
    final envDir = env['AELMAM_DIR'] ?? env['AELMAM_CLINIC_DIR'];
    if (envDir != null) {
      addDirConfig(envDir, expandHome: true);
    }
  }

  try {
    if (Platform.isWindows) {
      addDirConfig(windowsDataDir);
      addDirConfig(legacyWindowsDataDir);
      if (env != null) {
        addDirConfig(env['APPDATA'] == null
            ? null
            : p.join(env['APPDATA']!, 'aelmam_clinic'));
        addDirConfig(env['LOCALAPPDATA'] == null
            ? null
            : p.join(env['LOCALAPPDATA']!, 'aelmam_clinic'));
      }
    } else if (Platform.isLinux) {
      addDirConfig(linuxDataDir, expandHome: true);
      addDirConfig('~/.config/aelmam_clinic', expandHome: true);
      if (env != null) {
        final xdg = env['XDG_CONFIG_HOME'];
        if (xdg != null && xdg.trim().isNotEmpty) {
          addDirConfig(
            p.join(expandHomeDir(xdg), 'aelmam_clinic'),
          );
        }
      }
    } else if (Platform.isMacOS) {
      addDirConfig(macOsDataDir, expandHome: true);
    } else if (Platform.isAndroid) {
      addDirConfig(androidDataDir);
    } else if (Platform.isIOS) {
      addDirConfig(iosLogicalDataDir);
    }
  } catch (_) {
    // ignore platform detection failures
  }

  try {
    addDirConfig(Directory.current.path);
  } catch (_) {
    // ignore inability to resolve current directory (e.g. in tests)
  }

  for (final path in candidatePaths) {
    try {
      final file = File(path);
      if (!await file.exists()) continue;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) continue;

      final data = jsonDecode(raw);
      if (data is! Map) {
        continue;
      }

      String? readKey(String key) {
        final value = data[key] ?? data[lowerSnake(key)];
        if (value == null) return null;
        if (value is String) {
          return value.trim();
        }
        return '$value'.trim();
      }

      List<String>? readEmailList() {
        final raw = data['superAdminEmails'] ??
            data['super_admin_emails'] ??
            data['superAdmins'] ??
            data['super_admins'];
        if (raw == null) return null;
        List<String> normalizeList(List list) {
          return list
              .map((e) => e?.toString().trim() ?? '')
              .where((value) => value.isNotEmpty)
              .toList();
        }

        if (raw is String) {
          final trimmed = raw.trim();
          return trimmed.isEmpty ? null : [trimmed];
        }
        if (raw is List) {
          final values = normalizeList(raw);
          return values.isEmpty ? null : values;
        }
        return null;
      }

      final nhostSubdomain = readKey('nhostSubdomain');
      final nhostRegion = readKey('nhostRegion');
      final nhostGraphqlUrl = readKey('nhostGraphqlUrl');
      final nhostAuthUrl = readKey('nhostAuthUrl');
      final nhostStorageUrl = readKey('nhostStorageUrl');
      final nhostFunctionsUrl = readKey('nhostFunctionsUrl');
      final nhostAdminSecret = readKey('nhostAdminSecret');
      final nhostWebhookSecret = readKey('nhostWebhookSecret');
      final nhostJwtSecret = readKey('nhostJwtSecret');
      final admins = readEmailList();

      final noNhostOverrides = (nhostSubdomain == null ||
              nhostSubdomain.isEmpty) &&
          (nhostRegion == null || nhostRegion.isEmpty) &&
          (nhostGraphqlUrl == null || nhostGraphqlUrl.isEmpty) &&
          (nhostAuthUrl == null || nhostAuthUrl.isEmpty) &&
          (nhostStorageUrl == null || nhostStorageUrl.isEmpty) &&
          (nhostFunctionsUrl == null || nhostFunctionsUrl.isEmpty) &&
          (nhostAdminSecret == null || nhostAdminSecret.isEmpty) &&
          (nhostWebhookSecret == null || nhostWebhookSecret.isEmpty) &&
          (nhostJwtSecret == null || nhostJwtSecret.isEmpty);

      if (noNhostOverrides && (admins == null || admins.isEmpty)) {
        continue;
      }

      return (
        superAdminEmails: admins,
        nhostSubdomain: nhostSubdomain,
        nhostRegion: nhostRegion,
        nhostGraphqlUrl: nhostGraphqlUrl,
        nhostAuthUrl: nhostAuthUrl,
        nhostStorageUrl: nhostStorageUrl,
        nhostFunctionsUrl: nhostFunctionsUrl,
        nhostAdminSecret: nhostAdminSecret,
        nhostWebhookSecret: nhostWebhookSecret,
        nhostJwtSecret: nhostJwtSecret,
        source: file.path,
      );
    } catch (_) {
      // ignore file read/parse errors and continue to the next candidate
    }
  }

  return null;
}

String expandHomeDir(String value) {
  if (!value.startsWith('~')) return value;
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    return value.replaceFirst('~', '');
  }
  return value.replaceFirst('~', home);
}

String lowerSnake(String camel) {
  final buffer = StringBuffer();
  for (var i = 0; i < camel.length; i++) {
    final char = camel[i];
    if (char.toUpperCase() == char && char.toLowerCase() != char && i > 0) {
      buffer.write('_');
    }
    buffer.write(char.toLowerCase());
  }
  return buffer.toString();
}
