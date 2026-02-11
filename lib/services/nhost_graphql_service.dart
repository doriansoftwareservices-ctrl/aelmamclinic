import 'package:flutter/foundation.dart';
import 'package:gql/ast.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:nhost_dart/nhost_dart.dart';

import '../core/auth_role_state.dart';
import '../core/nhost_config.dart';
import '../core/nhost_manager.dart';

/// يبني عملاء GraphQL معتمدين على Nhost ويحدّث رموز الدخول تلقائيًا.
class NhostGraphqlService {
  NhostGraphqlService._();

  static ValueNotifier<GraphQLClient>? _notifier;

  static HttpLink _buildHttpLink() => HttpLink(
        NhostConfig.graphqlUrl,
      );

  static bool _isSuperAdmin(NhostClient client) {
    final user = client.auth.currentUser;
    if (user != null) {
      final roles = user.roles;
      final hasRole =
          roles.any((role) => role.toLowerCase() == 'superadmin');
      return hasRole || user.defaultRole.toLowerCase() == 'superadmin';
    }
    return AuthRoleState.isSuperAdmin;
  }

  static WebSocketLink _buildWebSocketLink(NhostClient client) {
    return WebSocketLink(
      NhostConfig.graphqlWsUrl,
      config: SocketClientConfig(
        autoReconnect: true,
        inactivityTimeout: const Duration(seconds: 30),
        initialPayload: () async {
          final token = client.auth.accessToken;
          final isSuper = _isSuperAdmin(client);
          if (token == null || token.isEmpty) {
            return <String, dynamic>{};
          }
          return <String, dynamic>{
            'headers': {
              'Authorization': 'Bearer $token',
              if (isSuper) 'x-hasura-role': 'superadmin',
            },
          };
        },
      ),
    );
  }

  static Link _buildLink({NhostClient? client}) {
    final nhost = client ?? NhostManager.client;
    final httpLink = _buildHttpLink();
    final wsLink = _buildWebSocketLink(nhost);
    final retryLink = Link.function((request, [forward]) {
      if (forward == null) {
        return Stream.error(StateError('No next link'));
      }
      final isMutation = _isMutationRequest(request);
      final maxAttempts = isMutation ? 1 : 3;

      return _retryRequest(
        request: request,
        forward: forward,
        maxAttempts: maxAttempts,
      );
    });
    final roleLink = Link.function((request, [forward]) {
      final isSuper = _isSuperAdmin(nhost);
      if (!isSuper) return forward!(request);
      final existing =
          request.context.entry<HttpLinkHeaders>()?.headers ?? const {};
      request = request.updateContextEntry<HttpLinkHeaders>((entry) {
        final headers = entry?.headers ?? const <String, String>{};
        final merged = <String, String>{...headers, ...existing};
        merged.putIfAbsent('x-hasura-role', () => 'superadmin');
        return HttpLinkHeaders(headers: merged);
      });
      return forward!(request);
    });
    final authLink = AuthLink(
      getToken: () async {
        final access = nhost.auth.accessToken;
        return access != null && access.isNotEmpty ? 'Bearer $access' : null;
      },
    );
    final authedHttp = retryLink.concat(roleLink).concat(authLink).concat(
          httpLink,
        );
    return Link.split((request) => request.isSubscription, wsLink, authedHttp);
  }

  static bool _isMutationRequest(Request request) {
    for (final def in request.operation.document.definitions) {
      if (def is OperationDefinitionNode &&
          def.type == OperationType.mutation) {
        return true;
      }
    }
    return false;
  }

  static bool _shouldRetry(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('responseformatexception') ||
        msg.contains('formatexception') ||
        msg.contains('unexpected character') ||
        msg.contains('502') ||
        msg.contains('503') ||
        msg.contains('bad gateway') ||
        msg.contains('service temporarily unavailable') ||
        msg.contains('eof') ||
        msg.contains('context deadline exceeded');
  }

  static Stream<Response> _retryRequest({
    required Request request,
    required NextLink forward,
    required int maxAttempts,
  }) async* {
    var attempt = 0;
    while (true) {
      try {
        yield* forward(request);
        return;
      } catch (e) {
        attempt += 1;
        if (attempt >= maxAttempts || !_shouldRetry(e)) {
          rethrow;
        }
        await Future<void>.delayed(
          Duration(milliseconds: 350 * attempt),
        );
      }
    }
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
