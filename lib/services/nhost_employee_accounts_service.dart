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

  Future<void> ensureEmployeeDoctorRow({
    required String accountId,
    required String userUid,
    required bool isDoctor,
    String? name,
  }) async {
    if (accountId.isEmpty || userUid.isEmpty) return;
    const mutation = r'''
      mutation UpsertEmployeeDoctor(
        $account: uuid!,
        $uid: uuid!,
        $isDoctor: Boolean!,
        $name: String
      ) {
        insert_employees_one(
          object: {
            account_id: $account,
            user_uid: $uid,
            is_doctor: $isDoctor,
            name: $name
          },
          on_conflict: {
            constraint: employees_user_uid_key,
            update_columns: [account_id, user_uid, is_doctor, name]
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
          'account': accountId,
          'uid': userUid,
          'isDoctor': isDoctor,
          'name': name,
        },
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
  }
}
