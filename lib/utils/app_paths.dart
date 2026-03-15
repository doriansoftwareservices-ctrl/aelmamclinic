// lib/utils/app_paths.dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as pp;

class AppPaths {
  AppPaths._();

  static const String appFolderName = 'ElmamClinic';

  static List<String> windowsCandidates({String? override}) {
    final env = Platform.environment;
    final localBase = _resolveLocalAppData(env);
    if (override != null && override.trim().isNotEmpty) {
      final trimmed = override.trim();
      if (localBase != null &&
          localBase.trim().isNotEmpty &&
          (p.equals(p.normalize(trimmed), p.normalize(localBase)) ||
              p.isWithin(localBase, trimmed))) {
        return [trimmed];
      }
    }
    final base = localBase;
    final candidates = <String>[];
    if (base != null && base.trim().isNotEmpty) {
      candidates.add(p.join(base, appFolderName));
    }
    if (candidates.isEmpty) {
      candidates.add(p.join(Directory.systemTemp.path, appFolderName));
    }
    return candidates.toSet().toList();
  }

  static Future<String> pickWritableWindowsRoot({String? override}) async {
    for (final dirPath in windowsCandidates(override: override)) {
      try {
        final dir = Directory(dirPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        if (await _ensureWritable(dir)) {
          return dirPath;
        }
      } catch (_) {
        // try next
      }
    }
    return p.join(Directory.systemTemp.path, appFolderName);
  }

  static Future<Directory> dataRoot() async {
    if (Platform.isWindows) {
      final root = await pickWritableWindowsRoot();
      return Directory(root);
    }
    final support = await pp.getApplicationSupportDirectory();
    return Directory(p.join(support.path, appFolderName));
  }

  static Future<Directory> logsDir() async {
    final root = await dataRoot();
    final dir = Directory(p.join(root.path, 'logs'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> dbRootDir() async {
    final root = await dataRoot();
    await root.create(recursive: true);
    return root;
  }

  static Future<bool> _ensureWritable(Directory dir) async {
    try {
      final probe = File(p.join(dir.path, '.write_test'));
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String? _resolveLocalAppData(Map<String, String> env) {
    final direct = env['LOCALAPPDATA'];
    if (direct != null && direct.trim().isNotEmpty) {
      return direct.trim();
    }
    final profile = env['USERPROFILE'];
    if (profile != null && profile.trim().isNotEmpty) {
      return p.join(profile.trim(), 'AppData', 'Local');
    }
    final homeDrive = env['HOMEDRIVE'];
    final homePath = env['HOMEPATH'];
    if (homeDrive != null &&
        homeDrive.trim().isNotEmpty &&
        homePath != null &&
        homePath.trim().isNotEmpty) {
      return p.join(homeDrive.trim(), homePath.trim(), 'AppData', 'Local');
    }
    return null;
  }

  static Future<void> cleanupLegacyWindowsDirs({String? activeRoot}) async {
    if (!Platform.isWindows) return;
    final legacyDirs = <String>[
      r'D:\ElmamClinic',
      r'C:\ElmamClinic',
    ];
    for (final dirPath in legacyDirs) {
      try {
        if (activeRoot != null &&
            p.equals(p.normalize(activeRoot), p.normalize(dirPath))) {
          continue;
        }
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          if (activeRoot != null && activeRoot.trim().isNotEmpty) {
            try {
              await _mergeDir(dir, Directory(activeRoot));
            } catch (_) {}
          }
          await dir.delete(recursive: true);
        }
      } catch (_) {
        // تجاهل أي فشل في الحذف
      }
    }
  }

  static Future<void> _mergeDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final entity in src.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final targetPath = p.join(dst.path, name);
      if (entity is File) {
        final targetFile = File(targetPath);
        if (!await targetFile.exists()) {
          await targetFile.writeAsBytes(await entity.readAsBytes());
        }
      } else if (entity is Directory) {
        await _mergeDir(entity, Directory(targetPath));
      }
    }
  }
}
