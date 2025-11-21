import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<({String? supabaseUrl, String? supabaseAnonKey, List<String>? superAdminEmails, String? source})?>
    loadSupabaseRuntimeOverrides({
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
    addFile(env['AELMAM_SUPABASE_CONFIG'] ?? env['AELMAM_CONFIG']);
    addFile(env['AELMAM_CLINIC_CONFIG'] ?? env['SUPABASE_CONFIG_PATH']);
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

      final url = readKey('supabaseUrl');
      final anonKey = readKey('supabaseAnonKey');
      final admins = readEmailList();

      if ((url == null || url.isEmpty) &&
          (anonKey == null || anonKey.isEmpty) &&
          (admins == null || admins.isEmpty)) {
        continue;
      }

      return (
        supabaseUrl: url,
        supabaseAnonKey: anonKey,
        superAdminEmails: admins,
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
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
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
