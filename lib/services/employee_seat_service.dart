import 'dart:io';

import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:aelmamclinic/models/employee_seat_request.dart';
import 'package:aelmamclinic/services/nhost_api_client.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class EmployeeSeatService {
  EmployeeSeatService({GraphQLClient? client, NhostApiClient? api})
      : _gql = client ?? NhostGraphqlService.client,
        _api = api ?? NhostApiClient();

  final GraphQLClient _gql;
  final NhostApiClient _api;

  Future<Map<String, dynamic>> createEmployeeWithinLimit({
    required String email,
    required String password,
  }) async {
    return _callFunction('owner-create-employee', {
      'email': email,
      'password': password,
    });
  }

  Future<Map<String, dynamic>> requestExtraEmployee({
    required String email,
    required String password,
  }) async {
    return _callFunction('owner-request-extra-employee', {
      'email': email,
      'password': password,
    });
  }

  Future<Map<String, dynamic>?> fetchLatestSeatRequest({
    required String employeeUserUid,
  }) async {
    const query = r'''
      query LatestSeatRequest($uid: uuid!) {
        employee_seat_requests(
          where: {employee_user_uid: {_eq: $uid}}
          order_by: {created_at: desc}
          limit: 1
        ) {
          id
          status
          account_id
          employee_user_uid
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'uid': employeeUserUid},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = (res.data?['employee_seat_requests'] as List?) ?? const [];
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first as Map);
  }

  Future<List<EmployeeSeatRequest>> fetchPendingSeatRequests() async {
    const query = r'''
      query PendingSeatRequests {
        employee_seat_requests(
          where: {status: {_eq: "submitted"}}
          order_by: {created_at: desc}
        ) {
          id
          account_id
          requested_by_uid
          employee_user_uid
          employee_email
          status
          receipt_file_id
          admin_note
          created_at
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = (res.data?['employee_seat_requests'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) =>
            EmployeeSeatRequest.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> reviewSeatRequest({
    required String requestId,
    required bool approve,
    String? note,
  }) async {
    const mutation = r'''
      mutation ReviewSeatRequest($id: uuid!, $approve: Boolean!, $note: String) {
        superadmin_review_employee_seat_request(
          args: {p_request_id: $id, p_approve: $approve, p_note: $note}
        ) {
          ok
          error
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'id': requestId,
          'approve': approve,
          'note': note,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows =
        (res.data?['superadmin_review_employee_seat_request'] as List?) ??
            const [];
    final row = rows.isNotEmpty ? rows.first : null;
    if (row == null || row['ok'] != true) {
      final msg = row?['error']?.toString() ?? 'review_failed';
      throw HttpException(msg);
    }
  }

  Future<void> submitSeatPayment({
    required String requestId,
    required String paymentMethodId,
    required String receiptFileId,
  }) async {
    const mutation = r'''
      mutation SubmitSeatPayment(
        $request: uuid!
        $method: uuid!
        $receipt: String!
      ) {
        owner_submit_employee_seat_payment(
          args: {
            p_request_id: $request
            p_payment_method_id: $method
            p_receipt_file_id: $receipt
          }
        ) {
          ok
          error
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'request': requestId,
          'method': paymentMethodId,
          'receipt': receiptFileId,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows =
        (res.data?['owner_submit_employee_seat_payment'] as List?) ?? const [];
    final row = rows.isNotEmpty ? rows.first : null;
    if (row == null || row['ok'] != true) {
      final msg = row?['error']?.toString() ?? 'submit_failed';
      throw HttpException(msg);
    }
  }

  Future<Map<String, dynamic>> _callFunction(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final base = NhostConfig.functionsUrl.replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/$name');
    return _api.postJson(url, payload);
  }

  void dispose() => _api.dispose();
}
