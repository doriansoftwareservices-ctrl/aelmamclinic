import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/models/complaint.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/payment_plan_stat.dart';
import 'package:aelmamclinic/models/payment_stat.dart';
import 'package:aelmamclinic/models/payment_time_stat.dart';
import 'package:aelmamclinic/models/subscription_request.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class AdminBillingService {
  AdminBillingService({GraphQLClient? client})
      : _gql = client ?? NhostGraphqlService.client;

  final GraphQLClient _gql;

  Future<List<SubscriptionRequest>> fetchSubscriptionRequests() async {
    const query = r'''
      query Requests {
        subscription_requests(order_by: {created_at: desc}) {
          id
          account_id
          user_uid
          plan_code
          status
          amount
          payment_method_id
          proof_url
          reference_text
          sender_name
          clinic_name
          created_at
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['subscription_requests'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) =>
            SubscriptionRequest.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> approveRequest(String requestId, {String? note}) async {
    const mutation = r'''
      mutation Approve($id: uuid!, $note: String) {
        admin_approve_subscription_request(args: {p_request: $id, p_note: $note}) {
          ok
          error
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'id': requestId, 'note': note},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows =
        (res.data?['admin_approve_subscription_request'] as List?) ?? const [];
    final ok = rows.isEmpty ? null : (rows.first as Map)['ok'];
    if (ok != true) {
      final err = rows.isEmpty ? null : (rows.first as Map)['error'];
      throw Exception(err ?? 'Approve failed');
    }
  }

  Future<void> rejectRequest(String requestId, {String? note}) async {
    const mutation = r'''
      mutation Reject($id: uuid!, $note: String) {
        admin_reject_subscription_request(args: {p_request: $id, p_note: $note}) {
          ok
          error
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'id': requestId, 'note': note},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows =
        (res.data?['admin_reject_subscription_request'] as List?) ?? const [];
    final ok = rows.isEmpty ? null : (rows.first as Map)['ok'];
    if (ok != true) {
      final err = rows.isEmpty ? null : (rows.first as Map)['error'];
      throw Exception(err ?? 'Reject failed');
    }
  }

  Future<List<PaymentMethod>> fetchPaymentMethods() async {
    const query = r'''
      query Methods {
        payment_methods(order_by: {created_at: desc}) {
          id
          name
          logo_url
          bank_account
          is_active
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['payment_methods'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => PaymentMethod.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> createPaymentMethod({
    required String name,
    required String bankAccount,
    String? logoUrl,
  }) async {
    const mutation = r'''
      mutation CreateMethod($name: String!, $bank: String!, $logo: String) {
        insert_payment_methods_one(object: {
          name: $name,
          bank_account: $bank,
          logo_url: $logo
        }) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'name': name, 'bank': bankAccount, 'logo': logoUrl},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<void> updatePaymentMethod({
    required String id,
    required String name,
    required String bankAccount,
    String? logoUrl,
    required bool isActive,
  }) async {
    const mutation = r'''
      mutation UpdateMethod($id: uuid!, $name: String!, $bank: String!, $logo: String, $active: Boolean!) {
        update_payment_methods_by_pk(pk_columns: {id: $id}, _set: {
          name: $name,
          bank_account: $bank,
          logo_url: $logo,
          is_active: $active
        }) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'id': id,
          'name': name,
          'bank': bankAccount,
          'logo': logoUrl,
          'active': isActive
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<void> deletePaymentMethod(String id) async {
    const mutation = r'''
      mutation DeleteMethod($id: uuid!) {
        delete_payment_methods_by_pk(id: $id) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'id': id},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<List<Complaint>> fetchComplaints() async {
    const query = r'''
      query Complaints {
        complaints(order_by: {created_at: desc}) {
          id
          account_id
          user_uid
          status
          subject
          message
          created_at
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['complaints'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => Complaint.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> updateComplaintStatus({
    required String id,
    required String status,
  }) async {
    const mutation = r'''
      mutation UpdateComplaint($id: uuid!, $status: String!) {
        update_complaints_by_pk(pk_columns: {id: $id}, _set: {status: $status}) { id }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'id': id, 'status': status},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<List<PaymentStat>> fetchPaymentStats() async {
    const query = r'''
      query Stats {
        admin_payment_stats {
          payment_method_id
          payment_method_name
          total_amount
          payments_count
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['admin_payment_stats'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => PaymentStat.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<PaymentPlanStat>> fetchPaymentStatsByPlan() async {
    const query = r'''
      query StatsByPlan {
        admin_payment_stats_by_plan {
          plan_code
          total_amount
          payments_count
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) throw res.exception!;
    final rows =
        (res.data?['admin_payment_stats_by_plan'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => PaymentPlanStat.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<PaymentTimeStat>> fetchPaymentStatsByDay() async {
    const query = r'''
      query StatsByDay {
        admin_payment_stats_by_day {
          day
          total_amount
          payments_count
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) throw res.exception!;
    final rows = (res.data?['admin_payment_stats_by_day'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => PaymentTimeStat.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<PaymentTimeStat>> fetchPaymentStatsByMonth() async {
    const query = r'''
      query StatsByMonth {
        admin_payment_stats_by_month {
          month
          total_amount
          payments_count
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) throw res.exception!;
    final rows =
        (res.data?['admin_payment_stats_by_month'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => PaymentTimeStat.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }
}
