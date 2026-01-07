import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/models/admin_account_member.dart';
import 'package:aelmamclinic/models/admin_account_member_count.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class AdminAccountMembersService {
  AdminAccountMembersService({GraphQLClient? client})
      : _gql = client ?? NhostGraphqlService.client;

  final GraphQLClient _gql;

  Future<List<AdminAccountMemberCount>> fetchMemberCounts({
    bool onlyActive = true,
  }) async {
    const query = r'''
      query AccountMemberCounts($onlyActive: Boolean!) {
        admin_dashboard_account_member_counts(
          args: {p_only_active: $onlyActive}
        ) {
          account_id
          account_name
          owners_count
          admins_count
          employees_count
          total_members
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'onlyActive': onlyActive},
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows =
        (res.data?['admin_dashboard_account_member_counts'] as List?) ??
            const [];
    return rows
        .whereType<Map>()
        .map((row) =>
            AdminAccountMemberCount.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<AdminAccountMember>> fetchMembers({
    String? accountId,
    bool onlyActive = true,
  }) async {
    const query = r'''
      query AccountMembers($account: uuid, $onlyActive: Boolean!) {
        admin_dashboard_account_members(
          args: {p_account: $account, p_only_active: $onlyActive}
        ) {
          account_id
          account_name
          user_uid
          email
          role
          disabled
          created_at
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {
          'account': accountId,
          'onlyActive': onlyActive,
        },
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows =
        (res.data?['admin_dashboard_account_members'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map(
            (row) => AdminAccountMember.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }
}
