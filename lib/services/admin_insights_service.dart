import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:aelmamclinic/models/admin_action_log.dart';
import 'package:aelmamclinic/models/admin_system_health.dart';
import 'package:aelmamclinic/models/admin_usage_metrics.dart';
import 'package:aelmamclinic/models/admin_risk_alert.dart';
import 'package:aelmamclinic/models/admin_audit_activity.dart';
import 'package:aelmamclinic/models/admin_audit_actor.dart';
import 'package:aelmamclinic/models/admin_usage_daily.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class AdminInsightsService {
  AdminInsightsService({GraphQLClient? client})
      : _gql = client ?? NhostGraphqlService.client;

  final GraphQLClient _gql;

  Context _superAdminContext() {
    return Context.fromList(const [
      HttpLinkHeaders(headers: {'x-hasura-role': 'superadmin'}),
    ]);
  }

  Future<AdminSystemHealth?> fetchSystemHealth() async {
    const query = r'''
      query Health {
        v_admin_system_health(limit: 1) {
          storage_files
          chat_attachments
          pending_subscriptions
          server_time
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['v_admin_system_health'] as List?) ?? const [];
    if (rows.isEmpty) return null;
    final first = rows.first;
    if (first is! Map) return null;
    return AdminSystemHealth.fromJson(Map<String, dynamic>.from(first));
  }

  Future<List<AdminActionLog>> fetchActionLogs({
    int limit = 50,
    int offset = 0,
  }) async {
    const query = r'''
      query AdminActionLogs($limit: Int!, $offset: Int!) {
        admin_action_logs(
          order_by: {created_at: desc},
          limit: $limit,
          offset: $offset
        ) {
          id
          actor_uid
          actor_email
          action
          entity_type
          entity_id
          details
          created_at
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'limit': limit, 'offset': offset},
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['admin_action_logs'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => AdminActionLog.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> logAction({
    required String action,
    required String entityType,
    String? entityId,
    Map<String, dynamic>? details,
  }) async {
    const mutation = r'''
      mutation LogAction($action: String!, $type: String!, $id: String, $details: jsonb) {
        admin_log_action(args: {
          p_action: $action,
          p_entity_type: $type,
          p_entity_id: $id,
          p_details: $details
        })
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'action': action,
          'type': entityType,
          'id': entityId,
          'details': details,
        },
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<AdminUsageMetrics?> fetchUsageMetrics() async {
    const query = r'''
      query UsageMetrics {
        v_admin_usage_metrics(limit: 1) {
          accounts
          account_users
          chat_messages_30d
          chat_attachments
          audit_events_7d
          active_users_30d
          server_time
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['v_admin_usage_metrics'] as List?) ?? const [];
    if (rows.isEmpty) return null;
    final raw = rows.first;
    if (raw is Map) {
      return AdminUsageMetrics.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  Future<List<AdminRiskAlert>> fetchRiskAlerts() async {
    const query = r'''
      query RiskAlerts {
        v_admin_risk_alerts {
          code
          severity
          title
          count
          hint
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['v_admin_risk_alerts'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((e) => AdminRiskAlert.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<AdminAuditActivity>> fetchAuditActivityDaily({
    int limit = 60,
    int offset = 0,
  }) async {
    const query = r'''
      query AuditDaily($limit: Int!, $offset: Int!) {
        v_admin_audit_activity_daily(
          order_by: {day: desc},
          limit: $limit,
          offset: $offset
        ) {
          day
          table_name
          op
          events
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'limit': limit, 'offset': offset},
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows =
        (res.data?['v_admin_audit_activity_daily'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => AdminAuditActivity.fromMap(
            Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<AdminAuditActor>> fetchAuditTopActors({int limit = 20}) async {
    const query = r'''
      query AuditTopActors($limit: Int!) {
        v_admin_audit_top_actors(
          order_by: {events: desc},
          limit: $limit
        ) {
          actor_uid
          actor_email
          events
          last_at
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'limit': limit},
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows =
        (res.data?['v_admin_audit_top_actors'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => AdminAuditActor.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<AdminUsageDaily>> fetchUsageDaily({int limit = 30}) async {
    const query = r'''
      query UsageDaily($limit: Int!) {
        v_admin_usage_daily(order_by: {day: desc}, limit: $limit) {
          day
          messages
          attachments
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'limit': limit},
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['v_admin_usage_daily'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) =>
            AdminUsageDaily.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }
}
