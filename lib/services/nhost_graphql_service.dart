import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:nhost_dart/nhost_dart.dart';

import '../core/nhost_config.dart';
import '../core/nhost_manager.dart';

/// يبني عملاء GraphQL معتمدين على Nhost ويحدّث رموز الدخول تلقائيًا.
class NhostGraphqlService {
  NhostGraphqlService._();

  static final HttpLink _httpLink = HttpLink(
    NhostConfig.graphqlUrl,
  );

  static GraphQLClient buildClient({NhostClient? client}) {
    final nhost = client ?? NhostManager.client;

    final AuthLink authLink = AuthLink(
      getToken: () async {
        final access = nhost.auth.accessToken;
        return access != null && access.isNotEmpty ? 'Bearer $access' : null;
      },
    );

    final Link link = authLink.concat(_httpLink);

    return GraphQLClient(
      link: link,
      cache: GraphQLCache(store: InMemoryStore()),
    );
  }

  /// يوفر `ValueNotifier` مناسبًا لربطه مع `GraphQLProvider`.
  static ValueNotifier<GraphQLClient> buildNotifier({NhostClient? client}) {
    return ValueNotifier<GraphQLClient>(buildClient(client: client));
  }
}
