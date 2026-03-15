import 'dart:io';
import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:aelmamclinic/models/super_admin_account.dart';
import 'package:aelmamclinic/services/nhost_api_client.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/admin_insights_service.dart';

class SuperAdminAccountsService {
  SuperAdminAccountsService({GraphQLClient? client, NhostApiClient? api})
      : _gql = client ?? NhostGraphqlService.client,
        _api = api ?? NhostApiClient();

  final GraphQLClient _gql;
  final NhostApiClient _api;

  Context _superAdminContext() {
    return Context.fromList(const [
      HttpLinkHeaders(headers: {'x-hasura-role': 'superadmin'}),
    ]);
  }

  Future<List<SuperAdminAccount>> fetchSuperAdmins() async {
    const query = r'''
      query SuperAdmins {
        admin_list_super_admin_accounts {
          email
          user_uid
          created_at
          disabled
          default_role
          allowed_tabs
          has_user
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
    if (res.hasException) {
      throw res.exception!;
    }
    final rows =
        (res.data?['admin_list_super_admin_accounts'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) =>
            SuperAdminAccount.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<String>> fetchMyAllowedTabs() async {
    const query = r'''
      query MySuperAdminTabs {
        admin_get_super_admin_tabs {
          allowed_tabs
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
    if (res.hasException) {
      final fallback = await _fetchMyAllowedTabsFromView();
      if (fallback.isNotEmpty ||
          _isMissingFieldException(res.exception, const [
            'admin_get_super_admin_tabs',
          ])) {
        return fallback;
      }
      throw res.exception!;
    }
    final rows =
        (res.data?['admin_get_super_admin_tabs'] as List?) ?? const [];
    if (rows.isEmpty) return const [];
    final row = rows.first;
    if (row is Map<String, dynamic>) {
      return _parseTabsValue(row['allowed_tabs']);
    }
    return const [];
  }

  Future<List<String>> _fetchMyAllowedTabsFromView() async {
    const query = r'''
      query MySuperAdminTabsFallback {
        v_super_admin_tabs(limit: 1) {
          allowed_tabs
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
    if (res.hasException) {
      if (_isMissingFieldException(res.exception, const [
        'v_super_admin_tabs',
        'admin_get_super_admin_tabs',
      ])) {
        return const [];
      }
      throw res.exception!;
    }
    final rows = (res.data?['v_super_admin_tabs'] as List?) ?? const [];
    if (rows.isEmpty) return const [];
    final row = rows.first;
    if (row is Map<String, dynamic>) {
      return _parseTabsValue(row['allowed_tabs']);
    }
    return const [];
  }

  bool _isMissingFieldException(
    OperationException? exception,
    List<String> fieldNames,
  ) {
    if (exception == null) return false;
    final message = exception.graphqlErrors.isEmpty
        ? exception.toString()
        : exception.graphqlErrors.map((e) => e.message).join(' | ');
    final lower = message.toLowerCase();
    final mentionsField =
        fieldNames.any((field) => lower.contains(field.toLowerCase()));
    return mentionsField &&
        (lower.contains('not found in type') ||
            lower.contains('validation-failed') ||
            lower.contains('field') && lower.contains('not found'));
  }

  Future<void> setAllowedTabs({
    required String userUid,
    required List<String> allowedTabs,
  }) async {
    const mutation = r'''
      mutation SetSuperAdminTabs($uid: uuid!, $tabs: _text) {
        admin_set_super_admin_tabs(
          args: {p_user_uid: $uid, p_allowed_tabs: $tabs}
        ) {
          ok
          error
          user_uid
        }
      }
    ''';
    String toPgArray(List<String> values) {
      if (values.isEmpty) return '{}';
      final escaped = values.map((v) {
        final s = v.replaceAll('\\', '\\\\').replaceAll('\"', '\\\"');
        return '\"$s\"';
      }).join(',');
      return '{$escaped}';
    }
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'uid': userUid,
          'tabs': toPgArray(allowedTabs),
        },
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = res.data?['admin_set_super_admin_tabs'];
    _ensureOkJson(rows, 'تعذّر تحديث تبويبات السوبر أدمن.');
    try {
      await AdminInsightsService().logAction(
        action: 'superadmin_tabs_update',
        entityType: 'superadmin',
        entityId: userUid,
        details: {'tabs': allowedTabs},
      );
    } catch (_) {}
  }

  Future<void> setDisabled({
    required String email,
    required bool disabled,
  }) async {
    const mutation = r'''
      mutation SetSuperAdminDisabled($email: String!, $disabled: Boolean!) {
        admin_set_super_admin_disabled(
          args: {p_email: $email, p_disabled: $disabled}
        ) {
          ok
          error
          user_uid
          disabled
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {
          'email': email,
          'disabled': disabled,
        },
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = res.data?['admin_set_super_admin_disabled'];
    _ensureOkJson(rows, 'تعذّر تغيير حالة الحساب.');
    try {
      await AdminInsightsService().logAction(
        action: disabled ? 'superadmin_disable' : 'superadmin_enable',
        entityType: 'superadmin',
        entityId: email,
      );
    } catch (_) {}
  }

  Future<void> deleteSuperAdmin({
    required String email,
  }) async {
    const mutation = r'''
      mutation DeleteSuperAdmin($email: String!) {
        admin_delete_super_admin(args: {p_email: $email}) {
          ok
          error
          user_uid
        }
      }
    ''';
    final res = await _gql.mutate(
      MutationOptions(
        document: gql(mutation),
        variables: {'email': email},
        fetchPolicy: FetchPolicy.noCache,
        context: _superAdminContext(),
      ),
    );
    if (res.hasException) {
      throw res.exception!;
    }
    final rows = res.data?['admin_delete_super_admin'];
    _ensureOkJson(rows, 'تعذّر حذف حساب السوبر أدمن.');
    try {
      await AdminInsightsService().logAction(
        action: 'superadmin_delete',
        entityType: 'superadmin',
        entityId: email,
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> createSuperAdmin({
    required String email,
    required String password,
    required List<String> allowedTabs,
  }) async {
    final base = NhostConfig.functionsUrl.replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/admin-create-superadmin');
    try {
      final res = await _api.postJson(url, {
        'email': email,
        'password': password,
        'allowed_tabs': allowedTabs,
      });
      try {
        await AdminInsightsService().logAction(
          action: 'superadmin_create',
          entityType: 'superadmin',
          entityId: email,
          details: {'tabs': allowedTabs},
        );
      } catch (_) {}
      return res;
    } on HttpException {
      rethrow;
    } catch (e) {
      throw Exception('Functions call failed: $e');
    }
  }

  Future<void> resetSuperAdminPassword({
    required String email,
    required String newPassword,
  }) async {
    final base = NhostConfig.functionsUrl.replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/admin-reset-superadmin-password');
    try {
      final res = await _api.postJson(url, {
        'email': email,
        'new_password': newPassword,
      });
      if (res['ok'] == true) return;
      try {
        await AdminInsightsService().logAction(
          action: 'superadmin_reset_password',
          entityType: 'superadmin',
          entityId: email,
        );
      } catch (_) {}
      throw Exception(res['error'] ?? 'تعذّر تغيير كلمة المرور.');
    } on HttpException {
      rethrow;
    } catch (e) {
      throw Exception('Functions call failed: $e');
    }
  }

  void dispose() {
    _api.dispose();
  }

  void _ensureOkJson(dynamic payload, String fallback) {
    Map? row;
    if (payload is List && payload.isNotEmpty && payload.first is Map) {
      row = payload.first as Map;
    } else if (payload is Map) {
      row = payload;
    }
    if (row != null && row['ok'] == true) {
      return;
    }
    final msg = row?['error']?.toString() ?? fallback;
    throw Exception(msg);
  }

  List<String> _parsePgTextArray(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      final inner = trimmed.substring(1, trimmed.length - 1).trim();
      if (inner.isEmpty) return const [];
      return inner
          .split(',')
          .map((e) => e.trim().replaceAll('\"', ''))
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  List<String> _parseTabsValue(dynamic tabs) {
    if (tabs == null) return const [];
    if (tabs is List) {
      if (tabs.length == 1 && tabs.first is String) {
        final single = (tabs.first as String).trim();
        if (single.startsWith('{') && single.endsWith('}')) {
          return _parsePgTextArray(single);
        }
      }
      return tabs.map((e) => e.toString()).toList();
    }
    if (tabs is String && tabs.isNotEmpty) {
      return _parsePgTextArray(tabs);
    }
    return const [];
  }
}
