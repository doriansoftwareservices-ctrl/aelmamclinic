// lib/utils/app_paths.dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as pp;

class AppPaths {
  AppPaths._();

  static const String appFolderName = 'ElmamClinic';

  static List<String> windowsCandidates({String? override}) {
    if (override != null && override.trim().isNotEmpty) {
      return [override.trim()];
    }
    final env = Platform.environment;
    final base = env['LOCALAPPDATA'] ?? env['APPDATA'];
    final candidates = <String>[];
    if (base != null && base.trim().isNotEmpty) {
      candidates.add(p.join(base, appFolderName));
    }
    candidates.add(r'D:\ElmamClinic');
    candidates.add(r'C:\ElmamClinic');
    candidates.add(p.join(Directory.systemTemp.path, appFolderName));
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
      return Directory(await pickWritableWindowsRoot());
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
}
