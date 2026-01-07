/// Static configuration for the Nhost backend.
///
/// Values can be overridden at runtime via `--dart-define` when launching the
/// Flutter application. The defaults reflect the environment shared by the user.
class NhostConfig {
  const NhostConfig._();

  static const String _fallbackSubdomain = 'mergrgclboxflnucehgb';
  static const String _fallbackRegion = 'ap-southeast-1';

  static final String _defaultSubdomain = const String.fromEnvironment(
    'NHOST_SUBDOMAIN',
    defaultValue: _fallbackSubdomain,
  );
  static String? _overrideSubdomain;

  static final String _defaultRegion = const String.fromEnvironment(
    'NHOST_REGION',
    defaultValue: _fallbackRegion,
  );
  static String? _overrideRegion;

  static final String _defaultGraphqlUrl = const String.fromEnvironment(
    'NHOST_GRAPHQL_URL',
    defaultValue:
        'https://mergrgclboxflnucehgb.graphql.ap-southeast-1.nhost.run/v1',
  );
  static String? _overrideGraphqlUrl;

  static final String _defaultAuthUrl = const String.fromEnvironment(
    'NHOST_AUTH_URL',
    defaultValue:
        'https://mergrgclboxflnucehgb.auth.ap-southeast-1.nhost.run/v1',
  );
  static String? _overrideAuthUrl;

  static final String _defaultStorageUrl = const String.fromEnvironment(
    'NHOST_STORAGE_URL',
    defaultValue:
        'https://mergrgclboxflnucehgb.storage.ap-southeast-1.nhost.run/v1',
  );
  static String? _overrideStorageUrl;

  static final String _defaultFunctionsUrl = const String.fromEnvironment(
    'NHOST_FUNCTIONS_URL',
    defaultValue:
        'https://mergrgclboxflnucehgb.functions.ap-southeast-1.nhost.run/v1',
  );
  static String? _overrideFunctionsUrl;

  static final String _defaultResetPasswordRedirectUrl =
      const String.fromEnvironment(
    'NHOST_PASSWORD_RESET_REDIRECT_URL',
    defaultValue: '',
  );
  static String? _overrideResetPasswordRedirectUrl;

  /// Nhost project subdomain (e.g. `mergrgclboxflnucehgb`).
  static String get subdomain =>
      _overrideSubdomain ??
      _normalizeOrFallback(_defaultSubdomain, _fallbackSubdomain);

  /// Nhost region (e.g. `ap-southeast-1`).
  static String get region =>
      _overrideRegion ?? _normalizeOrFallback(_defaultRegion, _fallbackRegion);

  /// REST endpoints exposed by Nhost services.
  static String get graphqlUrl {
    final candidate = _overrideGraphqlUrl ?? _defaultGraphqlUrl;
    if (candidate.trim().isNotEmpty) {
      return candidate;
    }
    return _buildServiceUrl('graphql');
  }

  /// WebSocket endpoint for Hasura subscriptions (derived from graphqlUrl).
  static String get graphqlWsUrl {
    final httpUrl = graphqlUrl.trim();
    if (httpUrl.startsWith('https://')) {
      return 'wss://${httpUrl.substring('https://'.length)}';
    }
    if (httpUrl.startsWith('http://')) {
      return 'ws://${httpUrl.substring('http://'.length)}';
    }
    return httpUrl.replaceFirst('https://', 'wss://').replaceFirst(
          'http://',
          'ws://',
        );
  }

  static String get authUrl {
    final candidate = _overrideAuthUrl ?? _defaultAuthUrl;
    if (candidate.trim().isNotEmpty) {
      return candidate;
    }
    return _buildServiceUrl('auth');
  }

  static String get storageUrl {
    final candidate = _overrideStorageUrl ?? _defaultStorageUrl;
    if (candidate.trim().isNotEmpty) {
      return candidate;
    }
    return _buildServiceUrl('storage');
  }

  static String get functionsUrl {
    final candidate = _overrideFunctionsUrl ?? _defaultFunctionsUrl;
    if (candidate.trim().isNotEmpty) {
      return candidate;
    }
    return _buildServiceUrl('functions');
  }

  /// Optional URL for password reset redirects (used when email links are sent).
  static String get resetPasswordRedirectUrl =>
      _overrideResetPasswordRedirectUrl ?? _defaultResetPasswordRedirectUrl;

  static String _normalizeOrFallback(String value, String fallback) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static String _buildServiceUrl(String service) {
    final sub = subdomain.trim();
    final reg = region.trim();
    if (sub.isEmpty || reg.isEmpty) {
      return '';
    }
    return 'https://$sub.$service.$reg.nhost.run/v1';
  }

  static void applyOverrides({
    String? subdomain,
    String? region,
    String? graphqlUrl,
    String? authUrl,
    String? storageUrl,
    String? functionsUrl,
    String? resetPasswordRedirectUrl,
  }) {
    String? normalize(String? value) {
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty) {
        return null;
      }
      return trimmed;
    }

    _overrideSubdomain = normalize(subdomain) ?? _overrideSubdomain;
    _overrideRegion = normalize(region) ?? _overrideRegion;
    _overrideGraphqlUrl = normalize(graphqlUrl) ?? _overrideGraphqlUrl;
    _overrideAuthUrl = normalize(authUrl) ?? _overrideAuthUrl;
    _overrideStorageUrl = normalize(storageUrl) ?? _overrideStorageUrl;
    _overrideFunctionsUrl = normalize(functionsUrl) ?? _overrideFunctionsUrl;
    _overrideResetPasswordRedirectUrl = normalize(resetPasswordRedirectUrl) ??
        _overrideResetPasswordRedirectUrl;
  }
}
