import 'package:nhost_dart/nhost_dart.dart';

import 'nhost_config.dart';

/// Provides a lazily initialized [NhostClient] that can be reused across the
/// application. This layer encapsulates environment defaults and makes it easy
/// to swap the client (useful for tests).
class NhostManager {
  NhostManager._();

  static NhostClient? _client;

  /// Returns the shared [NhostClient] instance, creating it on first access.
  static NhostClient get client => _client ??= _buildClient();

  /// Allows overriding the internally managed [NhostClient] (e.g. in tests).
  static void overrideClient(NhostClient? newClient) {
    _client = newClient;
  }

  static NhostClient _buildClient() {
    return NhostClient(
      subdomain: NhostConfig.subdomain,
      region: NhostConfig.region,
      adminSecret:
          NhostConfig.adminSecret.isEmpty ? null : NhostConfig.adminSecret,
      authUrlOverride: NhostConfig.authUrl.isEmpty ? null : NhostConfig.authUrl,
      graphqlUrlOverride:
          NhostConfig.graphqlUrl.isEmpty ? null : NhostConfig.graphqlUrl,
      storageUrlOverride:
          NhostConfig.storageUrl.isEmpty ? null : NhostConfig.storageUrl,
      functionsUrlOverride: NhostConfig.functionsUrl.isEmpty
          ? null
          : NhostConfig.functionsUrl,
    );
  }
}
