import 'dart:ffi';
import 'dart:io';

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
    final candidates = <String>[
      r'C:\sqlite\sqlite3.dll',
      'sqlite3.dll',
    ];
    for (final path in candidates) {
      try {
        open.overrideForAll(() => DynamicLibrary.open(path));
        _sqlitePatched = true;
        return;
      } catch (_) {
        // جرّب المسار التالي
      }
    }
  }
}
