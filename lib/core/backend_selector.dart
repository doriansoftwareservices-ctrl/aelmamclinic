enum BackendTarget { supabase, nhost }

/// Determines which backend should be used at runtime. By default the legacy
/// Supabase backend remains active to avoid breaking existing flows, but the
/// value can be overridden using `--dart-define BACKEND=nhost`.
class BackendSelector {
  BackendSelector._();

  static const String _envBackend = String.fromEnvironment(
    'BACKEND',
    defaultValue: 'supabase',
  );

  static BackendTarget get current {
    switch (_envBackend.toLowerCase().trim()) {
      case 'nhost':
        return BackendTarget.nhost;
      default:
        return BackendTarget.supabase;
    }
  }
}
