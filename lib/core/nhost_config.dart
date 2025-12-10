/// Static configuration for the Nhost backend.
///
/// Values can be overridden at runtime via `--dart-define` when launching the
/// Flutter application. The defaults reflect the environment shared by the user.
class NhostConfig {
  const NhostConfig._();

  /// Nhost project subdomain (e.g. `plbwpsqxtizkxnqgxgfm`).
  static const String subdomain = String.fromEnvironment(
    'NHOST_SUBDOMAIN',
    defaultValue: 'plbwpsqxtizkxnqgxgfm',
  );

  /// Nhost region (e.g. `ap-southeast-1`).
  static const String region = String.fromEnvironment(
    'NHOST_REGION',
    defaultValue: 'ap-southeast-1',
  );

  /// REST endpoints exposed by Nhost services.
  static const String graphqlUrl = String.fromEnvironment(
    'NHOST_GRAPHQL_URL',
    defaultValue:
        'https://plbwpsqxtizkxnqgxgfm.graphql.ap-southeast-1.nhost.run/v1',
  );

  static const String authUrl = String.fromEnvironment(
    'NHOST_AUTH_URL',
    defaultValue:
        'https://plbwpsqxtizkxnqgxgfm.auth.ap-southeast-1.nhost.run/v1',
  );

  static const String storageUrl = String.fromEnvironment(
    'NHOST_STORAGE_URL',
    defaultValue:
        'https://plbwpsqxtizkxnqgxgfm.storage.ap-southeast-1.nhost.run/v1',
  );

  static const String functionsUrl = String.fromEnvironment(
    'NHOST_FUNCTIONS_URL',
    defaultValue:
        'https://plbwpsqxtizkxnqgxgfm.functions.ap-southeast-1.nhost.run/v1',
  );

  /// Optional secrets used for privileged calls.
  static const String adminSecret = String.fromEnvironment(
    'NHOST_ADMIN_SECRET',
    defaultValue: '',
  );

  static const String webhookSecret = String.fromEnvironment(
    'NHOST_WEBHOOK_SECRET',
    defaultValue: '',
  );

  static const String jwtSecret = String.fromEnvironment(
    'NHOST_JWT_SECRET',
    defaultValue: '',
  );
}
