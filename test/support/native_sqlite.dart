import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

bool _sqlitePatched = false;

/// Ensures that the sqlite3 dynamic library is reachable for sqflite FFI tests.
///
/// On Linux the package manager installs `libsqlite3.so` under
/// `/usr/lib/x86_64-linux-gnu`, بينما على Windows نتوقّع وجود
/// `sqlite3.dll` ضمن المسار الافتراضي للتطبيق. استدعاء الدالة أكثر من
/// مرة آمن – تتم العملية مرة واحدة فقط في عمر العملية.
void ensureNativeSqlite() {
  if (_sqlitePatched) return;

  if (Platform.isLinux) {
    open.overrideForAll(() => DynamicLibrary.open('libsqlite3.so'));
    _sqlitePatched = true;
    return;
  }

  if (Platform.isMacOS) {
    open.overrideForAll(() => DynamicLibrary.open('libsqlite3.dylib'));
    _sqlitePatched = true;
    return;
  }

  if (Platform.isWindows) {
    final cwd = Directory.current.path;
    final envPath = Platform.environment['SQLITE_DLL_PATH'];
    final candidates = <String>[
      if (envPath != null && envPath.isNotEmpty) envPath,
      p.join(cwd, 'build', 'windows', 'x64', 'runner', 'Debug', 'sqlite3.dll'),
      p.join(cwd, 'build', 'windows', 'runner', 'Debug', 'sqlite3.dll'),
      p.join(cwd, 'windows', 'runner', 'Debug', 'sqlite3.dll'),
      'sqlite3.dll',
      r'C:\sqlite\sqlite3.dll',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (!file.existsSync()) {
        continue;
      }
      try {
        open.overrideForAll(() => DynamicLibrary.open(file.path));
        _sqlitePatched = true;
        return;
      } catch (_) {
        // جرّب المسار التالي
      }
    }
    throw StateError(
      'Unable to locate sqlite3.dll for desktop tests. '
      'Ensure you have built the Windows runner (flutter run -d windows) or '
      'set SQLITE_DLL_PATH to a valid sqlite3.dll.',
    );
  }
}
