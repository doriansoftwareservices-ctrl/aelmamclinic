import 'dart:io';

/// Controls whether the application is allowed to talk to any remote backend.
///
/// When [isOffline] is true the app must not perform HTTP requests nor attempt
/// to initialize backend clients. Use [enforceOfflineNetwork] early in the boot
/// process to globally block outbound sockets.
class BackendLock {
  BackendLock._();

  /// Compile-time flag to disable every backend integration.
  static const bool isOffline = bool.fromEnvironment(
    'BACKEND_DISABLED',
    defaultValue: false,
  );

  /// Installs a global [HttpOverrides] that aborts any attempt to create an
  /// outbound HTTP client. Should be invoked once when [isOffline] is true.
  static void enforceOfflineNetwork() {
    if (!isOffline) return;
    if (HttpOverrides.current is _BackendDisabledHttpOverrides) {
      return;
    }
    HttpOverrides.global = _BackendDisabledHttpOverrides();
  }
}

class _BackendDisabledHttpOverrides extends HttpOverrides {
  _BackendDisabledHttpOverrides();

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw const BackendDisabledException();
  }
}

class BackendDisabledException implements IOException {
  const BackendDisabledException();

  @override
  String toString() =>
      'BackendDisabledException: network access is disabled in this build';
}
