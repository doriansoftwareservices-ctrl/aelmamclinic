import 'dart:io';

import 'package:graphql_flutter/graphql_flutter.dart';

import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/models/account_user_summary.dart';
import 'package:aelmamclinic/models/clinic.dart';
import 'package:aelmamclinic/models/provisioning_result.dart';
import 'package:aelmamclinic/services/nhost_api_client.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';

class NhostAdminService {
  NhostAdminService({GraphQLClient? client, NhostApiClient? api})
      : _gqlOverride = client,
        _api = api ?? NhostApiClient();

  final GraphQLClient? _gqlOverride;
  final NhostApiClient _api;
  GraphQLClient get _gql => _gqlOverride ?? NhostGraphqlService.client;

  static const String _defaultSuperAdminEmail = 'admin@elmam.com';

  static List<String> get _configuredSuperAdmins {
    final emails = AppConstants.superAdminEmails;
    if (emails.isEmpty) {
      return const [_defaultSuperAdminEmail];
    }
    return emails.map((e) => e.toLowerCase()).toSet().toList();
  }

  bool get isSuperAdmin {
    final user = NhostManager.client.auth.currentUser;
    final email = user?.email;
    if (email == null || email.isEmpty) return false;
    if (_configuredSuperAdmins.contains(email.toLowerCase())) return true;
    final role = user?.defaultRole.toLowerCase();
    if (role == 'superadmin') return true;
    final roles = user?.roles.map((r) => r.toLowerCase()).toList() ?? const [];
    return roles.contains('superadmin');
  }

  void _ensureSuperAdminOrThrow() {
    if (!isSuperAdmin) {
      throw StateError('هذه العملية مخصّصة للسوبر أدمن فقط.');
    }
  }

  Future<void> signOut() => NhostManager.client.auth.signOut();

  Future<List<Clinic>> fetchClinics() async {
    _ensureSuperAdminOrThrow();
    const query = '''
      query AdminClinics {
        admin_list_clinics {
          id
          name
          frozen
          created_at
        }
      }
    ''';
    final data = await _runQuery(query, const {});
    final rows = (data['admin_list_clinics'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((row) => Clinic.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<ProvisioningResult> createClinicAccount({
    required String clinicName,
    required String ownerEmail,
    required String ownerPassword,
  }) async {
    _ensureSuperAdminOrThrow();
    final payload = {
      'clinic_name': clinicName.trim(),
      'owner_email': ownerEmail.trim(),
      'owner_password': ownerPassword,
    };
    final res = await _callFunctionJson('admin-create-owner', payload);
    return _parseProvisioningResult(res, role: 'owner');
  }

  Future<ProvisioningResult> createEmployeeAccount({
    required String clinicId,
    required String email,
    required String password,
  }) async {
    _ensureSuperAdminOrThrow();
    final payload = {
      'account_id': clinicId,
      'email': email.trim(),
      'password': password,
    };
    final res = await _callFunctionJson('admin-create-employee', payload);
    return _parseProvisioningResult(res, role: 'employee');
  }

  Future<void> freezeClinic(String accountId, bool frozen) async {
    _ensureSuperAdminOrThrow();
    const mutation = '''
      mutation FreezeClinic(\$id: uuid!, \$frozen: Boolean!) {
        admin_set_clinic_frozen(args: {p_account_id: \$id, p_frozen: \$frozen})
      }
    ''';
    final data = await _runMutation(mutation, {
      'id': accountId,
      'frozen': frozen,
    });
    _ensureOkJson(data['admin_set_clinic_frozen'], 'تعذّر تغيير حالة العيادة.');
  }

  Future<void> deleteClinic(String accountId) async {
    _ensureSuperAdminOrThrow();
    const mutation = '''
      mutation DeleteClinic(\$id: uuid!) {
        admin_delete_clinic(args: {p_account_id: \$id})
      }
    ''';
    final data = await _runMutation(mutation, {'id': accountId});
    _ensureOkJson(data['admin_delete_clinic'], 'تعذّر حذف العيادة.');
  }

  Future<List<AccountUserSummary>> listAccountUsersWithEmail({
    required String accountId,
    bool includeDisabled = true,
  }) async {
    const query = '''
      query EmployeesWithEmail(\$accountId: uuid!) {
        list_employees_with_email(args: {p_account: \$accountId}) {
          user_uid
          email
          disabled
          role
        }
      }
    ''';
    final data = await _runQuery(query, {'accountId': accountId});
    final rows = (data['list_employees_with_email'] as List?) ?? const [];
    final list = rows.whereType<Map>().map((row) {
      final map = Map<String, dynamic>.from(row);
      return AccountUserSummary(
        userUid: map['user_uid']?.toString() ?? '',
        email: map['email']?.toString() ?? '',
        disabled: map['disabled'] == true,
      );
    }).toList();
    if (includeDisabled) return list;
    return list.where((u) => !u.disabled).toList();
  }

  Future<void> setEmployeeDisabled({
    required String accountId,
    required String userUid,
    required bool disabled,
  }) async {
    const mutation = '''
      mutation SetEmployeeDisabled(\$accountId: uuid!, \$uid: uuid!, \$disabled: Boolean!) {
        set_employee_disabled(args: {p_account: \$accountId, p_user_uid: \$uid, p_disabled: \$disabled})
      }
    ''';
    final data = await _runMutation(mutation, {
      'accountId': accountId,
      'uid': userUid,
      'disabled': disabled,
    });
    _ensureOkJson(data['set_employee_disabled'], 'تعذّر تغيير حالة الموظف.');
  }

  Future<void> deleteEmployee({
    required String accountId,
    required String userUid,
  }) async {
    const mutation = '''
      mutation DeleteEmployee(\$accountId: uuid!, \$uid: uuid!) {
        delete_employee(args: {p_account: \$accountId, p_user_uid: \$uid})
      }
    ''';
    final data = await _runMutation(mutation, {
      'accountId': accountId,
      'uid': userUid,
    });
    _ensureOkJson(data['delete_employee'], 'تعذّر حذف الموظف.');
  }

  Future<Map<String, dynamic>> _runQuery(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final result = await _gql.query(
      QueryOptions(
        document: gql(doc),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (result.hasException) {
      throw result.exception!;
    }
    return result.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _runMutation(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final result = await _gql.mutate(
      MutationOptions(
        document: gql(doc),
        variables: variables,
        fetchPolicy: FetchPolicy.noCache,
      ),
    );
    if (result.hasException) {
      throw result.exception!;
    }
    return result.data ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _callFunctionJson(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final base = NhostConfig.functionsUrl.replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/$name');
    try {
      final res = await _api.postJson(url, payload);
      return res;
    } on HttpException {
      rethrow;
    } catch (e) {
      throw Exception('Functions call failed: $e');
    }
  }

  ProvisioningResult _parseProvisioningResult(
    Map<String, dynamic> res, {
    required String role,
  }) {
    if (res['ok'] == true) {
      return ProvisioningResult(
        accountId: res['account_id']?.toString(),
        userUid: res['user_uid']?.toString() ?? res['owner_uid']?.toString(),
        role: role,
        warnings: (res['warnings'] as List?)
            ?.map((e) => e.toString())
            .toList(),
      );
    }
    final err = res['error']?.toString() ?? 'عملية الإدارة فشلت.';
    throw Exception(err);
  }

  void _ensureOkJson(dynamic payload, String fallback) {
    if (payload is Map && payload['ok'] == true) {
      return;
    }
    final msg = (payload is Map ? payload['error']?.toString() : null) ??
        fallback;
    throw Exception(msg);
  }
}
