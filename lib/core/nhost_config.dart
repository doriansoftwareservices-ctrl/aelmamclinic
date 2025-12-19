/// Static configuration for the Nhost backend.
///
/// Values can be overridden at runtime via `--dart-define` when launching the
/// Flutter application. The defaults reflect the environment shared by the user.
class NhostConfig {
  const NhostConfig._();

  static final String _defaultSubdomain = const String.fromEnvironment(
    'NHOST_SUBDOMAIN',
    defaultValue: 'plbwpsqxtizkxnqgxgfm',
  );
  static String? _overrideSubdomain;

  static final String _defaultRegion = const String.fromEnvironment(
    'NHOST_REGION',
    defaultValue: 'ap-southeast-1',
  );
  static String? _overrideRegion;

  static final String _defaultGraphqlUrl = const String.fromEnvironment(
    'NHOST_GRAPHQL_URL',
    defaultValue:
        'https://plbwpsqxtizkxnqgxgfm.graphql.ap-southeast-1.nhost.run/v1',
  );
  static String? _overrideGraphqlUrl;

  static final String _defaultAuthUrl = const String.fromEnvironment(
    'NHOST_AUTH_URL',
    defaultValue:
        'https://plbwpsqxtizkxnqgxgfm.auth.ap-southeast-1.nhost.run/v1',
  );
  static String? _overrideAuthUrl;

  static final String _defaultStorageUrl = const String.fromEnvironment(
    'NHOST_STORAGE_URL',
    defaultValue:
        'https://plbwpsqxtizkxnqgxgfm.storage.ap-southeast-1.nhost.run/v1',
  );
  static String? _overrideStorageUrl;

  static final String _defaultFunctionsUrl = const String.fromEnvironment(
    'NHOST_FUNCTIONS_URL',
    defaultValue:
        'https://plbwpsqxtizkxnqgxgfm.functions.ap-southeast-1.nhost.run/v1',
  );
  static String? _overrideFunctionsUrl;

  static final String _defaultAdminSecret = const String.fromEnvironment(
    'NHOST_ADMIN_SECRET',
    defaultValue: '',
  );
  static String? _overrideAdminSecret;

  static final String _defaultWebhookSecret = const String.fromEnvironment(
    'NHOST_WEBHOOK_SECRET',
    defaultValue: '',
  );
  static String? _overrideWebhookSecret;

  static final String _defaultJwtSecret = const String.fromEnvironment(
    'NHOST_JWT_SECRET',
    defaultValue: '',
  );
  static String? _overrideJwtSecret;

  /// Nhost project subdomain (e.g. `plbwpsqxtizkxnqgxgfm`).
  static String get subdomain => _overrideSubdomain ?? _defaultSubdomain;

  /// Nhost region (e.g. `ap-southeast-1`).
  static String get region => _overrideRegion ?? _defaultRegion;

  /// REST endpoints exposed by Nhost services.
  static String get graphqlUrl => _overrideGraphqlUrl ?? _defaultGraphqlUrl;

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

  static String get authUrl => _overrideAuthUrl ?? _defaultAuthUrl;

  static String get storageUrl => _overrideStorageUrl ?? _defaultStorageUrl;

  static String get functionsUrl =>
      _overrideFunctionsUrl ?? _defaultFunctionsUrl;

  /// Optional secrets used for privileged calls.
  static String get adminSecret => _overrideAdminSecret ?? _defaultAdminSecret;

  static String get webhookSecret =>
      _overrideWebhookSecret ?? _defaultWebhookSecret;

  static String get jwtSecret => _overrideJwtSecret ?? _defaultJwtSecret;

  static void applyOverrides({
    String? subdomain,
    String? region,
    String? graphqlUrl,
    String? authUrl,
    String? storageUrl,
    String? functionsUrl,
    String? adminSecret,
    String? webhookSecret,
    String? jwtSecret,
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
    _overrideAdminSecret = normalize(adminSecret) ?? _overrideAdminSecret;
    _overrideWebhookSecret =
        normalize(webhookSecret) ?? _overrideWebhookSecret;
    _overrideJwtSecret = normalize(jwtSecret) ?? _overrideJwtSecret;
  }
}
