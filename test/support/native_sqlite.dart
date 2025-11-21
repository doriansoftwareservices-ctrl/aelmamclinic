import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

bool _sqlitePatched = false;

/// Ensures that the sqlite3 dynamic library is reachable for sqflite FFI tests.
///
/// Returns `true` when a native library override is successfully registered.
/// On Linux the package manager installs `libsqlite3.so` under
/// `/usr/lib/x86_64-linux-gnu`, بينما على Windows نتوقّع وجود
/// `sqlite3.dll` ضمن المسار الافتراضي للتطبيق. استدعاء الدالة أكثر من
/// مرة آمن – تتم العملية مرة واحدة فقط في عمر العملية.
bool ensureNativeSqlite() {
  if (_sqlitePatched) return true;

  if (Platform.isLinux) {
    open.overrideForAll(() => DynamicLibrary.open('libsqlite3.so'));
    _sqlitePatched = true;
    return true;
  }

  if (Platform.isMacOS) {
    open.overrideForAll(() => DynamicLibrary.open('libsqlite3.dylib'));
    _sqlitePatched = true;
    return true;
  }

  if (Platform.isWindows) {
    final candidates = <String>[
      r'C:\\sqlite\\sqlite3.dll',
      'sqlite3.dll',
    ];
    for (final path in candidates) {
      try {
        if (path.contains('\\') && !File(path).existsSync()) {
          continue;
        }

        final lib = DynamicLibrary.open(path);
        open.overrideForAll(() => lib);
        _sqlitePatched = true;
        return true;
      } catch (_) {
        // جرّب المسار التالي
      }
    }

    return false;
  }

  return false;
}
