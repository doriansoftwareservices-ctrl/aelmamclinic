import 'package:flutter/foundation.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:nhost_dart/nhost_dart.dart';

import '../core/nhost_config.dart';
import '../core/nhost_manager.dart';

/// يبني عملاء GraphQL معتمدين على Nhost ويحدّث رموز الدخول تلقائيًا.
class NhostGraphqlService {
  NhostGraphqlService._();

  static ValueNotifier<GraphQLClient>? _notifier;

  static HttpLink _buildHttpLink() => HttpLink(
        NhostConfig.graphqlUrl,
      );

  static WebSocketLink _buildWebSocketLink(NhostClient client) {
    return WebSocketLink(
      NhostConfig.graphqlWsUrl,
      config: SocketClientConfig(
        autoReconnect: true,
        inactivityTimeout: const Duration(seconds: 30),
        initialPayload: () async {
          final token = client.auth.accessToken;
          if (token == null || token.isEmpty) {
            return <String, dynamic>{};
          }
          return <String, dynamic>{
            'headers': {'Authorization': 'Bearer $token'},
          };
        },
      ),
    );
  }

  static Link _buildLink({NhostClient? client}) {
    final nhost = client ?? NhostManager.client;
    final httpLink = _buildHttpLink();
    final wsLink = _buildWebSocketLink(nhost);
    final authLink = AuthLink(
      getToken: () async {
        final access = nhost.auth.accessToken;
        return access != null && access.isNotEmpty ? 'Bearer $access' : null;
      },
    );
    final authedHttp = authLink.concat(httpLink);
    return Link.split((request) => request.isSubscription, wsLink, authedHttp);
  }

  static GraphQLClient buildClient({NhostClient? client}) {
    return GraphQLClient(
      link: _buildLink(client: client),
      cache: GraphQLCache(store: InMemoryStore()),
    );
  }

  /// يوفر `ValueNotifier` مناسبًا لربطه مع `GraphQLProvider`.
  static ValueNotifier<GraphQLClient> buildNotifier({NhostClient? client}) {
    _notifier ??= ValueNotifier<GraphQLClient>(buildClient(client: client));
    return _notifier!;
  }

  /// يعيد عميل GraphQL الحالي (يتحدث عند refreshClient).
  static GraphQLClient get client => buildNotifier().value;

  /// يعيد إنشاء العميل لتحديث توكن الـ WebSocket بعد تجديد الجلسة.
  static void refreshClient({NhostClient? client}) {
    final next = buildClient(client: client);
    final notifier = buildNotifier(client: client);
    notifier.value = next;
  }
}
