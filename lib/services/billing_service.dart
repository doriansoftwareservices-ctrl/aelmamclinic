import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/subscription_plan.dart';
import 'package:aelmamclinic/services/clinic_profile_service.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class BillingService {
  BillingService({GraphQLClient? client})
      : _gql = client ?? NhostGraphqlService.client;

  final GraphQLClient _gql;

  Future<Map<String, dynamic>> fetchMyPlanDetails() async {
    const query = r'''
      query MyPlanDetails {
        my_account_plan {
          plan_code
          plan_end_at
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = (res.data?['my_account_plan'] as List?) ?? const [];
    if (rows.isEmpty) return {'plan_code': 'free', 'plan_end_at': null};
    return Map<String, dynamic>.from(rows.first as Map);
  }

  Future<List<SubscriptionPlan>> fetchPlans() async {
    const query = r'''
      query Plans {
        subscription_plans(order_by: {price_usd: asc}) {
          code
          name
          price_usd
          duration_months
          is_active
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = (res.data?['subscription_plans'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => SubscriptionPlan.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<String> fetchMyPlanCode() async {
    const query = r'''
      query MyPlan {
        my_account_plan {
          plan_code
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(document: gql(query), fetchPolicy: FetchPolicy.noCache),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = (res.data?['my_account_plan'] as List?) ?? const [];
    if (rows.isEmpty) return 'free';
    return (rows.first as Map)['plan_code']?.toString().toLowerCase() ?? 'free';
  }

  Future<List<PaymentMethod>> fetchPaymentMethods() async {
    const query = r'''
      query PaymentMethods {
        list_payment_methods {
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
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = (res.data?['list_payment_methods'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => PaymentMethod.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<String> createSubscriptionRequest({
    required String planCode,
    required String paymentMethodId,
    String? proofUrl,
    String? clinicName,
    String? referenceText,
    String? senderName,
  }) async {
    if (clinicName == null || clinicName.trim().isEmpty) {
      try {
        final profile = await ClinicProfileService.loadActiveOrFallback();
        if (profile.nameAr.trim().isNotEmpty) {
          clinicName = profile.nameAr.trim();
        }
      } catch (_) {}
    }
    const mutation = r'''
      mutation CreateRequest(
        $plan: String!
        $method: uuid!
        $proof: String
        $clinic: String
        $reference: String
        $sender: String
      ) {
        create_subscription_request(
          args: {
            p_plan: $plan
            p_payment_method: $method
            p_proof_url: $proof
            p_clinic_name: $clinic
            p_reference_text: $reference
            p_sender_name: $sender
          }
        ) {
          id
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'plan': planCode,
          'method': paymentMethodId,
          'proof': proofUrl,
          'clinic': clinicName,
          'reference': referenceText,
          'sender': senderName,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      final ex = res.exception!;
      final msg = ex.graphqlErrors.map((e) => e.message).join(' | ');
      final lowered = msg.toLowerCase();
      if (lowered.contains('database query error') ||
          lowered.contains('unexpected')) {
        final fallbackId = await _fallbackInsertSubscriptionRequest(
          planCode: planCode,
          paymentMethodId: paymentMethodId,
          proofUrl: proofUrl,
          clinicName: clinicName,
          referenceText: referenceText,
          senderName: senderName,
        );
        if (fallbackId.isNotEmpty) return fallbackId;
      }
      throw ex;
    }
    final rows =
        (res.data?['create_subscription_request'] as List?) ?? const [];
    if (rows.isEmpty) return '';
    return (rows.first as Map)['id']?.toString() ?? '';
  }

  Future<double?> _fetchPlanPrice(String planCode) async {
    const query = r'''
      query PlanPrice($code: String!) {
        subscription_plans(where: {code: {_eq: $code}}, limit: 1) {
          price_usd
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'code': planCode},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) return null;
    final rows = (res.data?['subscription_plans'] as List?) ?? const [];
    if (rows.isEmpty) return null;
    final v = (rows.first as Map)['price_usd'];
    return v is num ? v.toDouble() : double.tryParse(v.toString());
  }

  Future<String> _fallbackInsertSubscriptionRequest({
    required String planCode,
    required String paymentMethodId,
    String? proofUrl,
    String? clinicName,
    String? referenceText,
    String? senderName,
  }) async {
    final user = NhostManager.client.auth.currentUser;
    final userUid = user?.id ?? '';
    if (userUid.isEmpty) return '';

    final accountId =
        (user?.metadata?['account_id']?.toString() ?? '').trim();
    final activeAccount =
        accountId.isNotEmpty ? accountId : (await ActiveAccountStore.readAccountId() ?? '');
    if (activeAccount.trim().isEmpty) return '';

    final amount = await _fetchPlanPrice(planCode);
    const mutation = r'''
      mutation InsertSubReq($obj: subscription_requests_insert_input!) {
        insert_subscription_requests_one(object: $obj) {
          id
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'obj': {
            'account_id': activeAccount,
            'user_uid': userUid,
            'plan_code': planCode,
            'payment_method_id': paymentMethodId,
            'amount': amount,
            'proof_url': proofUrl,
            'reference_text': referenceText,
            'sender_name': senderName,
            'clinic_name': clinicName,
            'status': 'pending',
          }
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) return '';
    final row = res.data?['insert_subscription_requests_one'] as Map?;
    return row?['id']?.toString() ?? '';
  }
}
