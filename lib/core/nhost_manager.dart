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
    final authUrl = NhostConfig.authUrl.trim();
    final graphqlUrl = NhostConfig.graphqlUrl.trim();
    final storageUrl = NhostConfig.storageUrl.trim();
    final functionsUrl = NhostConfig.functionsUrl.trim();

    final hasServiceUrls = authUrl.isNotEmpty &&
        graphqlUrl.isNotEmpty &&
        storageUrl.isNotEmpty &&
        functionsUrl.isNotEmpty;

    return NhostClient(
      serviceUrls: hasServiceUrls
          ? ServiceUrls(
              authUrl: authUrl,
              graphqlUrl: graphqlUrl,
              storageUrl: storageUrl,
              functionsUrl: functionsUrl,
            )
          : null,
      subdomain: hasServiceUrls
          ? null
          : Subdomain(
              subdomain: NhostConfig.subdomain,
              region: NhostConfig.region,
            ),
    );
  }
}
