import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/core/nhost_manager.dart';
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

  Context _superAdminContext() {
    return Context.fromList(const [
      HttpLinkHeaders(headers: {'x-hasura-role': 'superadmin'}),
    ]);
  }

  Future<PaymentStatsBundle> fetchPaymentStatsBundle() async {
    try {
      final results = await Future.wait([
        fetchPaymentStats(),
        fetchPaymentStatsByPlan(),
        fetchPaymentStatsByMonth(),
        fetchPaymentStatsByDay(),
      ]);
      return PaymentStatsBundle(
        methods: results[0] as List<PaymentStat>,
        plans: results[1] as List<PaymentPlanStat>,
        monthly: results[2] as List<PaymentTimeStat>,
        daily: results[3] as List<PaymentTimeStat>,
      );
    } catch (_) {
      final payments = await _fetchPaymentsView();
      return PaymentStatsBundle(
        methods: _statsFromPayments(payments),
        plans: _planStatsFromPayments(payments),
        monthly: _timeStatsFromPayments(payments, byMonth: true),
        daily: _timeStatsFromPayments(payments, byMonth: false),
      );
    }
  }

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
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
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
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      final errors = res.exception?.graphqlErrors ?? const [];
      final msg = errors.isEmpty
          ? res.exception.toString()
          : errors.map((e) => e.message).join(' | ');
      throw Exception(msg);
    }
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
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      final errors = res.exception?.graphqlErrors ?? const [];
      final msg = errors.isEmpty
          ? res.exception.toString()
          : errors.map((e) => e.message).join(' | ');
      throw Exception(msg);
    }
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
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
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
        context: _superAdminContext(),
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
        context: _superAdminContext(),
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
        context: _superAdminContext(),
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
          reply_message
          replied_at
          replied_by
          created_at
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
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<void> replyToComplaint({
    required String id,
    required String replyMessage,
    String? status,
  }) async {
    const mutation = r'''
      mutation ReplyComplaint($id: uuid!, $reply: String!, $status: String) {
        admin_reply_complaint(args: {p_id: $id, p_reply: $reply, p_status: $status}) {
          ok
          error
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'id': id, 'reply': replyMessage, 'status': status},
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      final msg = res.exception?.graphqlErrors
              .map((e) => e.message)
              .join(' | ') ??
          res.exception.toString();
      if (msg.contains('admin_reply_complaint') &&
          msg.contains('not found')) {
        await _fallbackReplyComplaint(
          id: id,
          replyMessage: replyMessage,
          status: status,
        );
        return;
      }
      throw res.exception!;
    }
    final rows =
        (res.data?['admin_reply_complaint'] as List?) ?? const [];
    final ok = rows.isNotEmpty ? (rows.first as Map)['ok'] : null;
    if (ok != true) {
      final err = rows.isNotEmpty ? (rows.first as Map)['error'] : null;
      throw Exception(err ?? 'reply_failed');
    }
  }

  Future<void> _fallbackReplyComplaint({
    required String id,
    required String replyMessage,
    String? status,
  }) async {
    const mutation = r'''
      mutation ReplyFallback(
        $id: uuid!
        $reply: String!
        $status: String
        $repliedAt: timestamptz!
        $repliedBy: uuid
      ) {
        update_complaints_by_pk(
          pk_columns: {id: $id}
          _set: {
            reply_message: $reply
            replied_at: $repliedAt
            replied_by: $repliedBy
            handled_at: $repliedAt
            handled_by: $repliedBy
            status: $status
          }
        ) {
          id
        }
      }
    ''';
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final uid = NhostManager.client.auth.currentUser?.id;
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'id': id,
          'reply': replyMessage,
          'status': status,
          'repliedAt': nowIso,
          'repliedBy': uid,
        },
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
  }

  Future<PaymentStatsBundle> fetchPaymentStatsBundle() async {
    try {
      final results = await Future.wait([
        fetchPaymentStats(),
        fetchPaymentStatsByPlan(),
        fetchPaymentStatsByMonth(),
        fetchPaymentStatsByDay(),
      ]);
      return PaymentStatsBundle(
        methods: results[0] as List<PaymentStat>,
        plans: results[1] as List<PaymentPlanStat>,
        monthly: results[2] as List<PaymentTimeStat>,
        daily: results[3] as List<PaymentTimeStat>,
      );
    } catch (_) {
      final payments = await _fetchPaymentsView();
      return PaymentStatsBundle(
        methods: _statsFromPayments(payments),
        plans: _planStatsFromPayments(payments),
        monthly: _timeStatsFromPayments(payments, byMonth: true),
        daily: _timeStatsFromPayments(payments, byMonth: false),
      );
    }
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
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
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
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
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
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
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
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) throw res.exception!;
    final rows =
        (res.data?['admin_payment_stats_by_month'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => PaymentTimeStat.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<Map<String, dynamic>>> _fetchPaymentsView() async {
    const query = r'''
      query PaymentsView {
        v_admin_dashboard_payments {
          received_at
          plan_code
          amount_usd
          payment_method
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
    final rows = (res.data?['v_admin_dashboard_payments'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  static List<PaymentStat> _statsFromPayments(
      List<Map<String, dynamic>> rows) {
    final Map<String, _StatAgg> agg = {};
    for (final row in rows) {
      final method = row['payment_method']?.toString() ?? '—';
      final amount = _toDouble(row['amount_usd']);
      final entry = agg.putIfAbsent(method, () => _StatAgg(method));
      entry.total += amount;
      entry.count += 1;
    }
    return agg.values
        .map((a) => PaymentStat(
              paymentMethodId: null,
              paymentMethodName: a.key,
              totalAmount: a.total,
              paymentsCount: a.count,
            ))
        .toList()
      ..sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
  }

  static List<PaymentPlanStat> _planStatsFromPayments(
      List<Map<String, dynamic>> rows) {
    final Map<String, _StatAgg> agg = {};
    for (final row in rows) {
      final plan = row['plan_code']?.toString() ?? '—';
      final amount = _toDouble(row['amount_usd']);
      final entry = agg.putIfAbsent(plan, () => _StatAgg(plan));
      entry.total += amount;
      entry.count += 1;
    }
    return agg.values
        .map((a) => PaymentPlanStat(
              planCode: a.key,
              totalAmount: a.total,
              paymentsCount: a.count,
            ))
        .toList()
      ..sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
  }

  static List<PaymentTimeStat> _timeStatsFromPayments(
    List<Map<String, dynamic>> rows, {
    required bool byMonth,
  }) {
    final Map<String, _StatAgg> agg = {};
    for (final row in rows) {
      final raw = row['received_at']?.toString();
      if (raw == null) continue;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) continue;
      final keyDate = byMonth
          ? DateTime.utc(parsed.year, parsed.month, 1)
          : DateTime.utc(parsed.year, parsed.month, parsed.day);
      final key = keyDate.toIso8601String();
      final amount = _toDouble(row['amount_usd']);
      final entry = agg.putIfAbsent(key, () => _StatAgg(key));
      entry.total += amount;
      entry.count += 1;
    }
    return agg.values
        .map((a) => PaymentTimeStat(
              period: DateTime.tryParse(a.key),
              totalAmount: a.total,
              paymentsCount: a.count,
            ))
        .toList()
      ..sort((a, b) {
        final ad = a.period ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bd = b.period ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bd.compareTo(ad);
      });
  }
}

class PaymentStatsBundle {
  final List<PaymentStat> methods;
  final List<PaymentPlanStat> plans;
  final List<PaymentTimeStat> monthly;
  final List<PaymentTimeStat> daily;

  const PaymentStatsBundle({
    required this.methods,
    required this.plans,
    required this.monthly,
    required this.daily,
  });
}

class _StatAgg {
  _StatAgg(this.key);

  final String key;
  double total = 0;
  int count = 0;
}
