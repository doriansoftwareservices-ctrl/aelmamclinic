import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/models/admin_account_member.dart';
import 'package:aelmamclinic/models/admin_account_member_count.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class AdminAccountMembersService {
  AdminAccountMembersService({GraphQLClient? client})
      : _gql = client ?? NhostGraphqlService.client;

  final GraphQLClient _gql;
  static const _membersView = 'v_admin_dashboard_account_members';

  Context _superAdminContext() {
    return Context.fromList(const [
      HttpLinkHeaders(headers: {'x-hasura-role': 'superadmin'}),
    ]);
  }

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
        context: _superAdminContext(),
      ),
    );
    if (!res.hasException) {
      final rows =
          (res.data?['admin_dashboard_account_member_counts'] as List?) ??
              const [];
      return rows
          .whereType<Map>()
          .map((row) =>
              AdminAccountMemberCount.fromMap(Map<String, dynamic>.from(row)))
          .toList();
    }
    // Fallback: derive counts from members view (more robust if RPC fails).
    return _fallbackMemberCounts(onlyActive: onlyActive);
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
          chat_code
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
        context: _superAdminContext(),
      ),
    );
    if (!res.hasException) {
      final rows =
          (res.data?['admin_dashboard_account_members'] as List?) ?? const [];
      return rows
          .whereType<Map>()
          .map((row) =>
              AdminAccountMember.fromMap(Map<String, dynamic>.from(row)))
          .toList();
    }
    // Fallback to view-based query if RPC fails.
    return _fallbackMembers(
      accountId: accountId,
      onlyActive: onlyActive,
    );
  }

  Future<List<AdminAccountMember>> fetchMembersPage({
    String? accountId,
    required bool onlyActive,
    required int limit,
    required int offset,
  }) async {
    return _fallbackMembersPage(
      accountId: accountId,
      onlyActive: onlyActive,
      limit: limit,
      offset: offset,
    );
  }

  Future<Map<String, AdminAccountMember>> fetchOwnerMembersByAccountIds(
    List<String> accountIds,
  ) async {
    final ids =
        accountIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return {};
    const query = r'''
      query OwnerMembersForAccounts($ids: [uuid!]!) {
        v_admin_dashboard_account_members(
          where: {account_id: {_in: $ids}, role: {_eq: "owner"}}
        ) {
          account_id
          account_name
          user_uid
          email
          role
          disabled
          created_at
          chat_code
        }
      }
    ''';
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'ids': ids},
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows =
        (res.data?[_membersView] as List?) ?? const [];
    final out = <String, AdminAccountMember>{};
    for (final row in rows.whereType<Map>()) {
      final m = AdminAccountMember.fromMap(Map<String, dynamic>.from(row));
      if (m.accountId.isEmpty) continue;
      final existing = out[m.accountId];
      if (existing == null) {
        out[m.accountId] = m;
      } else if ((existing.chatCode ?? '').trim().isEmpty &&
          (m.chatCode ?? '').trim().isNotEmpty) {
        out[m.accountId] = m;
      }
    }
    return out;
  }

  Future<List<AdminAccountMember>> _fallbackMembers({
    String? accountId,
    required bool onlyActive,
  }) async {
    const query = r'''
      query MembersView($where: v_admin_dashboard_account_members_bool_exp) {
        v_admin_dashboard_account_members(where: $where) {
          account_id
          account_name
          user_uid
          email
          role
          disabled
          created_at
          chat_code
        }
      }
    ''';
    final Map<String, dynamic> where = {};
    if (accountId != null && accountId.isNotEmpty) {
      where['account_id'] = {'_eq': accountId};
    }
    if (onlyActive) {
      where['disabled'] = {'_eq': false};
    }
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {'where': where.isEmpty ? null : where},
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows =
        (res.data?[_membersView] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) =>
            AdminAccountMember.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<AdminAccountMember>> _fallbackMembersPage({
    String? accountId,
    required bool onlyActive,
    required int limit,
    required int offset,
  }) async {
    const query = r'''
      query MembersViewPage(
        $where: v_admin_dashboard_account_members_bool_exp
        $limit: Int!
        $offset: Int!
      ) {
        v_admin_dashboard_account_members(
          where: $where,
          limit: $limit,
          offset: $offset,
          order_by: {created_at: desc}
        ) {
          account_id
          account_name
          user_uid
          email
          role
          disabled
          created_at
          chat_code
        }
      }
    ''';
    final Map<String, dynamic> where = {};
    if (accountId != null && accountId.isNotEmpty) {
      where['account_id'] = {'_eq': accountId};
    }
    if (onlyActive) {
      where['disabled'] = {'_eq': false};
    }
    final res = await _gql.query(
      QueryOptions(
        document: gql(query),
        variables: {
          'where': where.isEmpty ? null : where,
          'limit': limit,
          'offset': offset,
        },
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows =
        (res.data?[_membersView] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) =>
            AdminAccountMember.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<AdminAccountMemberCount>> _fallbackMemberCounts({
    required bool onlyActive,
  }) async {
    final members =
        await _fallbackMembers(accountId: null, onlyActive: onlyActive);
    final Map<String, AdminAccountMemberCount> agg = {};
    for (final m in members) {
      final key = m.accountId;
      final existing = agg[key];
      final owners = (m.role.toLowerCase() == 'owner') ? 1 : 0;
      final admins = (m.role.toLowerCase() == 'admin') ? 1 : 0;
      final employees = (m.role.toLowerCase() == 'employee') ? 1 : 0;
      if (existing == null) {
        agg[key] = AdminAccountMemberCount(
          accountId: m.accountId,
          accountName: m.accountName,
          ownersCount: owners,
          adminsCount: admins,
          employeesCount: employees,
          totalMembers: 1,
        );
      } else {
        agg[key] = AdminAccountMemberCount(
          accountId: existing.accountId,
          accountName: existing.accountName,
          ownersCount: existing.ownersCount + owners,
          adminsCount: existing.adminsCount + admins,
          employeesCount: existing.employeesCount + employees,
          totalMembers: existing.totalMembers + 1,
        );
      }
    }
    return agg.values.toList();
  }
}
