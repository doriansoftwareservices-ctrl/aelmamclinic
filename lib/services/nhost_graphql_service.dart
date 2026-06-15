import 'package:flutter/foundation.dart';
import 'package:gql/ast.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:nhost_dart/nhost_dart.dart';
import 'package:aelmamclinic/l10n/raw_string_localizer.dart';
import 'package:aelmamclinic/utils/network_error_classifier.dart';
import 'package:aelmamclinic/services/nhost_dns_http_client.dart';

import '../core/auth_role_state.dart';
import '../core/nhost_config.dart';
import '../core/nhost_manager.dart';

/// يبني عملاء GraphQL معتمدين على Nhost ويحدّث رموز الدخول تلقائيًا.
class NhostGraphqlService {
  NhostGraphqlService._();

  static ValueNotifier<GraphQLClient>? _notifier;

  static HttpLink _buildHttpLink() {
    return HttpLink(
      NhostConfig.graphqlUrl,
      httpClient: NhostDnsHttpClient.createClient(),
    );
  }

  static bool _isSuperAdmin(NhostClient client) {
    // لا نثق بدور superadmin الخام الموجود في JWT قبل أن يثبته AuthProvider
    // من قاعدة البيانات. أي claim خاطئ أو قديم يجب ألا يجعل كل GraphQL يعمل
    // تلقائيًا بصلاحية superadmin، لأن ذلك قد يغيّر نتيجة my_profile ويوجه
    // حساب عيادة عادي إلى شاشة السوبر أدمن.
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
    final authedHttp = retryLink
        .concat(roleLink)
        .concat(authLink)
        .concat(httpLink);
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
    return NetworkErrorClassifier.isTransportLikeMessage(msg) ||
        NetworkErrorClassifier.isServerUnavailableLikeMessage(msg) ||
        msg.contains('context deadline exceeded');
  }

  static String _retryFailureMessage(Object error) {
    final raw = error.toString();
    if (NetworkErrorClassifier.isServerUnavailableLikeMessage(raw)) {
      return RawStringLocalizer.translateWithCurrentLocale(
        'تعذر الوصول إلى الخادم حاليًا. حاول مرة أخرى بعد قليل.',
      );
    }
    return RawStringLocalizer.translateWithCurrentLocale(
      'يبدو ان الشبكة غير مستقرة لديك',
    );
  }

  static Stream<Response> _retryRequest({
    required Request request,
    required NextLink forward,
    required int maxAttempts,
  }) async* {
    var attempt = 0;
    while (true) {
      try {
        await for (final resp in forward(request)) {
          yield resp;
        }
        return;
      } catch (e) {
        attempt += 1;
        if (attempt >= maxAttempts || !_shouldRetry(e)) {
          yield Response(
            response: const <String, dynamic>{},
            errors: [GraphQLError(message: _retryFailureMessage(e))],
          );
          return;
        }
        await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
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
