import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/models/employee_account_record.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class NhostEmployeeAccountsService {
  NhostEmployeeAccountsService({GraphQLClient? client})
      : _gql = client ?? NhostGraphqlService.client;

  final GraphQLClient _gql;

  Future<List<EmployeeAccountRecord>> listEmployees({
    required String accountId,
  }) async {
    const query = r'''
      query ListEmployees($account: uuid!) {
        list_employees_with_email(args: {p_account: $account}) {
          user_uid
          email
          role
          disabled
          created_at
          employee_id
          doctor_id
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'account': accountId},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = (res.data?['list_employees_with_email'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) =>
            EmployeeAccountRecord.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }
}
