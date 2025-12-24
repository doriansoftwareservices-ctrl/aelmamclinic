import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/models/payment_method.dart';
import 'package:aelmamclinic/models/subscription_plan.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class BillingService {
  BillingService({GraphQLClient? client}) : _gql = client ?? NhostGraphqlService.client;

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
    required double amount,
    String? proofUrl,
    String? referenceText,
    String? senderName,
  }) async {
    const mutation = r'''
      mutation CreateRequest(
        $plan: String!
        $method: uuid!
        $amount: numeric!
        $proof: String
        $reference: String
        $sender: String
      ) {
        create_subscription_request(
          args: {
            p_plan: $plan
            p_payment_method: $method
            p_amount: $amount
            p_proof_url: $proof
            p_reference_text: $reference
            p_sender_name: $sender
          }
        )
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'plan': planCode,
          'method': paymentMethodId,
          'amount': amount,
          'proof': proofUrl,
          'reference': referenceText,
          'sender': senderName,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    return res.data?['create_subscription_request']?.toString() ?? '';
  }
}
