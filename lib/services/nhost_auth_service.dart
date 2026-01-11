// lib/services/nhost_auth_service.dart
import 'dart:async';
import 'dart:developer' as dev;

import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:nhost_dart/nhost_dart.dart';
import 'package:nhost_sdk/nhost_sdk.dart' show AuthResponse, User;

import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/models/account_policy.dart';
import 'package:aelmamclinic/models/backend_errors.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/models/feature_permissions.dart';
import 'package:aelmamclinic/services/db_parity_v3.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/device_id_service.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/sync_service.dart';

/// مصادقة Nhost مع ربط المزامنة المحلية وحراسة الحساب.
/// توفر عمليات الدخول والخروج ومراقبة حالة الجلسة باستخدام `nhost_dart`.
class NhostAuthService {
  NhostAuthService({NhostClient? client, GraphQLClient? gql})
      : _client = client ?? NhostManager.client,
        _gqlOverride = gql {
    _authUnsub = _client.auth.addAuthStateChangedCallback((state) {
      // تحديث GraphQL client عند تغيّر الجلسة
      NhostGraphqlService.refreshClient(client: _client);

      // بثّ الحالة (بحذر)
      try {
        if (!_authStateController.isClosed) {
          _authStateController.add(state);
        }
      } catch (_) {}

      if (state == AuthenticationState.signedOut) {
        unawaited(_disposeSync());
      }
    });
  }

  final NhostClient _client;
  final GraphQLClient? _gqlOverride;

  final StreamController<AuthenticationState> _authStateController =
      StreamController<AuthenticationState>.broadcast();

  UnsubscribeDelegate? _authUnsub;

  SyncService? _sync;
  String? _boundAccountId;

  NhostClient get client => _client;

  /// يسجّل الدخول بواسطة البريد وكلمة السر.
  Future<AuthResponse> signInWithEmailPassword({
    required String email,
    required String password,
  }) {
    return _client.auth.signInEmailPassword(
      email: email.trim(),
      password: password,
    );
  }

  /// يسجّل الخروج من الجلسة الحالية.
  Future<void> signOut() async {
    await _client.auth.signOut();
    await _disposeSync();
  }

  /// يسجّل حسابًا جديدًا بالبريد وكلمة السر.
  Future<AuthResponse> signUpWithEmailPassword({
    required String email,
    required String password,
    String? locale,
  }) {
    return _client.auth.signUp(
      email: email.trim(),
      password: password,
      locale: locale,
    );
  }

  /// المستخدم الحالي (إن وُجد).
  User? get currentUser => _client.auth.currentUser;

  /// رمز الـ JWT الحالي (إن وُجد). يستخدم لاحقًا في GraphQL/Storage.
  String? get accessToken => _client.auth.accessToken;

  /// بث للتغييرات في حالة المصادقة (يساعد في تحديث مزودي الحالة).
  Stream<AuthenticationState> get authStateChanges =>
      _authStateController.stream;

  /// تغيير كلمة المرور للمستخدم الحالي.
  Future<void> changePassword(String newPassword) {
    return _client.auth.changePassword(newPassword: newPassword);
  }

  /// طلب إعادة تعيين كلمة المرور.
  Future<void> requestPasswordReset(String email, {String? redirectTo}) {
    final fallback = AppConstants.resetPasswordRedirectUrl.trim();
    final target = (redirectTo == null || redirectTo.trim().isEmpty)
        ? fallback
        : redirectTo;
    return _client.auth.resetPassword(
      email: email,
      redirectTo: target.isEmpty ? null : target,
    );
  }

  /// محاولة تحديث الجلسة من refreshToken (إن وُجد).
  Future<void> refreshSession() async {
    final refreshToken = _client.auth.userSession.session?.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return;
    await _client.auth.signInWithRefreshToken(refreshToken);
  }

  Future<void> dispose() async {
    _authUnsub?.call();
    _authUnsub = null;
    await _disposeSync();
    await _authStateController.close();
  }

  // ───────────────────────── GraphQL helpers ─────────────────────────

  GraphQLClient get _gql => _gqlOverride ?? NhostGraphqlService.client;

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
      final ex = result.exception!;
      if (_isSchemaError(ex)) {
        throw BackendSchemaException(_formatOperationException(ex));
      }
      throw ex;
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
      final ex = result.exception!;
      if (_isSchemaError(ex)) {
        throw BackendSchemaException(_formatOperationException(ex));
      }
      throw ex;
    }
    return result.data ?? <String, dynamic>{};
  }

  Future<String> selfCreateAccount({
    required ClinicProfileInput profile,
  }) async {
    const mutation = r'''
      mutation SelfCreateAccount(
        $name_ar: String!
        $city_ar: String!
        $street_ar: String!
        $near_ar: String!
        $name_en: String!
        $city_en: String!
        $street_en: String!
        $near_en: String!
        $phone: String!
      ) {
        self_create_account(
          args: {
            p_clinic_name: $name_ar
            p_city_ar: $city_ar
            p_street_ar: $street_ar
            p_near_ar: $near_ar
            p_clinic_name_en: $name_en
            p_city_en: $city_en
            p_street_en: $street_en
            p_near_en: $near_en
            p_phone: $phone
          }
        ) {
          id
        }
      }
    ''';

    final vars = <String, dynamic>{
      'name_ar': profile.nameAr.trim(),
      'city_ar': profile.cityAr.trim(),
      'street_ar': profile.streetAr.trim(),
      'near_ar': profile.nearAr.trim(),
      'name_en': profile.nameEn.trim(),
      'city_en': profile.cityEn.trim(),
      'street_en': profile.streetEn.trim(),
      'near_en': profile.nearEn.trim(),
      'phone': profile.phone.trim(),
    };

    final data = await _runMutation(mutation, vars);
    final rows = _rowsFromData(data, 'self_create_account');
    return rows.isEmpty ? '' : (rows.first['id']?.toString() ?? '');
  }

  Future<Map<String, dynamic>?> fetchClinicProfile({
    required String accountId,
  }) async {
    if (accountId.trim().isEmpty) return null;

    final data = await _runQuery(
      '''
      query ClinicProfile(\$id: uuid!) {
        accounts(where: {id: {_eq: \$id}}, limit: 1) {
          id
          name
          clinic_name_en
          city_ar
          street_ar
          near_ar
          city_en
          street_en
          near_en
          phone
        }
      }
      ''',
      {'id': accountId},
    );

    final rows = _rowsFromData(data, 'accounts');
    return rows.isEmpty ? null : rows.first;
  }

  List<Map<String, dynamic>> _rowsFromData(
    Map<String, dynamic> data,
    String key,
  ) {
    final raw = data[key];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  Future<Map<String, dynamic>?> _fetchMyProfileRow() async {
    try {
      final data = await _runQuery(
        '''
        query MyProfile {
          my_profile {
            id
            email
            account_id
            role
          }
        }
        ''',
        const {},
      );
      final rows = _rowsFromData(data, 'my_profile');
      return rows.isEmpty ? null : rows.first;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchAccountUserRow({
    required String uid,
    String? accountId,
  }) async {
    if (accountId != null && accountId.trim().isNotEmpty) {
      final data = await _runQuery(
        '''
        query AccountUserByAccount(\$uid: uuid!, \$account: uuid!) {
          account_users(
            where: {user_uid: {_eq: \$uid}, account_id: {_eq: \$account}}
            limit: 1
          ) {
            account_id
            role
            disabled
          }
        }
        ''',
        {'uid': uid, 'account': accountId},
      );
      final rows = _rowsFromData(data, 'account_users');
      return rows.isEmpty ? null : rows.first;
    }

    final data = await _runQuery(
      '''
      query AccountUserLatest(\$uid: uuid!) {
        account_users(
          where: {user_uid: {_eq: \$uid}}
          order_by: {created_at: desc}
          limit: 1
        ) {
          account_id
          role
          disabled
        }
      }
      ''',
      {'uid': uid},
    );
    final rows = _rowsFromData(data, 'account_users');
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> fetchMyPlanCode() async {
    try {
      final data = await _runQuery(
        '''
        query MyAccountPlan {
          my_account_plan {
            plan_code
          }
        }
        ''',
        const {},
      );
      final rows = _rowsFromData(data, 'my_account_plan');
      if (rows.isEmpty) return null;
      return rows.first['plan_code']?.toString();
    } catch (_) {
      return null;
    }
  }

  bool _isSchemaError(OperationException ex) {
    final message = _formatOperationException(ex);
    final lower = message.toLowerCase();
    return lower.contains('not found in type') ||
        (lower.contains('field') && lower.contains('not found')) ||
        (lower.contains('does not exist') && lower.contains('relation'));
  }

  String _formatOperationException(OperationException ex) {
    if (ex.graphqlErrors.isEmpty) {
      return ex.toString();
    }
    return ex.graphqlErrors.map((e) => e.message).join(' | ');
  }

  Future<bool> _resolveSuperAdminFlag({String? fallbackEmail}) async {
    const query = 'query { fn_is_super_admin_gql { is_super_admin } }';
    try {
      final data = await _runQuery(query, const {});
      final rows = data['fn_is_super_admin_gql'];
      if (rows is List && rows.isNotEmpty) {
        final flag = rows.first['is_super_admin'];
        if (flag is bool) {
          return flag;
        }
      }
      dev.log(
        'fn_is_super_admin_gql returned unexpected shape: ${rows.runtimeType}',
        name: 'AUTH',
      );
      return false;
    } catch (e, st) {
      dev.log(
        'fn_is_super_admin_gql query failed: $e',
        name: 'AUTH',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  Future<void> syncCurrentAccount(String? accountId) async {
    final trimmed = accountId?.trim() ?? '';
    if (trimmed.isEmpty) return;

    const mutation = r'''
      mutation SetCurrentAccount($account: uuid!) {
        set_current_account(args: {p_account: $account}) {
          id
        }
      }
    ''';

    try {
      await _runMutation(mutation, {'account': trimmed});
    } catch (_) {
      // Best-effort: ignore sync failures.
    }
  }

  /// يجلب معلومات المستخدم الحالي (accountId/role/disabled/isSuperAdmin).
  Future<Map<String, dynamic>> fetchCurrentUser() async {
    final user = _client.auth.currentUser;
    if (user == null) return <String, dynamic>{};

    String? accountId;
    String? role;
    bool disabled = false;

    try {
      final profile = await _fetchMyProfileRow();
      if (profile != null) {
        final profileAccount = profile['account_id']?.toString();
        if (profileAccount != null &&
            profileAccount.isNotEmpty &&
            profileAccount != 'null') {
          accountId = profileAccount;
        }
        role = profile['role']?.toString();
        if (accountId != null && accountId.isNotEmpty) {
          await ActiveAccountStore.writeAccountId(accountId);
        }
      }
    } catch (_) {}

    try {
      final preferred = await ActiveAccountStore.readAccountId();
      final row = await _fetchAccountUserRow(
            uid: user.id,
            accountId: preferred,
          ) ??
          await _fetchAccountUserRow(uid: user.id);
      if (row != null) {
        accountId ??= row['account_id']?.toString();
        role ??= row['role']?.toString();
        disabled = disabled || row['disabled'] == true;
        if (accountId != null && accountId.isNotEmpty) {
          await ActiveAccountStore.writeAccountId(accountId);
        }
      }
    } catch (_) {}

    final isSuper = await _resolveSuperAdminFlag(fallbackEmail: user.email);

    String? planCode;
    try {
      planCode = await fetchMyPlanCode() ?? 'free';
    } catch (_) {}

    return {
      'uid': user.id,
      'email': user.email,
      'accountId': accountId,
      'role': role,
      'disabled': disabled,
      'isSuperAdmin': isSuper,
      'planCode': planCode,
    };
  }

  Future<String?> resolveAccountId() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    try {
      final profile = await _fetchMyProfileRow();
      final acc = profile?['account_id']?.toString();
      if (acc != null && acc.isNotEmpty && acc != 'null') {
        await ActiveAccountStore.writeAccountId(acc);
        return acc;
      }
    } catch (_) {}

    final preferred = await ActiveAccountStore.readAccountId();
    if (preferred != null && preferred.isNotEmpty) {
      try {
        final row = await _fetchAccountUserRow(
          uid: user.id,
          accountId: preferred,
        );
        if (row != null) {
          return row['account_id']?.toString();
        }
      } catch (_) {}
    }

    try {
      final data =
          await _runQuery('query { my_account_id { account_id } }', const {});
      final rows = _rowsFromData(data, 'my_account_id');
      final acc = rows.isNotEmpty ? rows.first['account_id']?.toString() : null;
      if (acc != null && acc.isNotEmpty && acc != 'null') {
        await ActiveAccountStore.writeAccountId(acc);
        return acc;
      }
    } catch (_) {}

    try {
      final data = await _runQuery(
        '''
        query AccountIdFallback(\$uid: uuid!) {
          account_users(
            where: {user_uid: {_eq: \$uid}}
            order_by: {created_at: desc}
            limit: 1
          ) {
            account_id
          }
        }
        ''',
        {'uid': user.id},
      );
      final rows = _rowsFromData(data, 'account_users');
      if (rows.isNotEmpty) {
        final acc = rows.first['account_id']?.toString();
        if (acc != null && acc.isNotEmpty) {
          await ActiveAccountStore.writeAccountId(acc);
          return acc;
        }
      }
    } catch (_) {}

    return null;
  }

  Future<ActiveAccount> resolveActiveAccountOrThrow() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('Not signed in.');
    }

    String? accountId;
    String role = 'employee';
    bool roleResolved = false;
    bool disabled = false;
    String planCode = 'free';

    try {
      final profile = await _fetchMyProfileRow();
      if (profile != null) {
        final profileAccount = profile['account_id']?.toString();
        if (profileAccount != null &&
            profileAccount.isNotEmpty &&
            profileAccount != 'null') {
          accountId = profileAccount;
        }
        final profileRole = (profile['role'] as String?)?.trim();
        if (profileRole != null && profileRole.isNotEmpty) {
          role = profileRole;
          roleResolved = true;
        }
      }
    } catch (_) {}

    try {
      final preferred = await ActiveAccountStore.readAccountId();
      final row = await _fetchAccountUserRow(
            uid: user.id,
            accountId: preferred,
          ) ??
          await _fetchAccountUserRow(uid: user.id);
      if (row != null) {
        accountId ??= row['account_id']?.toString();
        final rowRole = (row['role'] as String?)?.trim();
        if (rowRole != null && rowRole.isNotEmpty) {
          role = rowRole;
          roleResolved = true;
        }
        disabled = disabled || row['disabled'] == true;
      }
    } catch (_) {}

    accountId ??= await resolveAccountId();
    if (accountId == null || accountId.isEmpty) {
      throw StateError('No active clinic found for this user.');
    }

    if (disabled) {
      throw AccountUserDisabledException(accountId);
    }

    try {
      planCode = await fetchMyPlanCode() ?? 'free';
    } catch (_) {}

    final roleLower = role.toLowerCase();
    if (roleResolved &&
        planCode == 'free' &&
        roleLower != 'owner' &&
        roleLower != 'admin' &&
        roleLower != 'superadmin') {
      throw PlanUpgradeRequiredException(accountId, planCode: planCode);
    }

    try {
      final data = await _runQuery(
        '''
        query ClinicFrozen(\$id: uuid!) {
          clinics(where: {id: {_eq: \$id}}, limit: 1) {
            frozen
          }
        }
        ''',
        {'id': accountId},
      );
      final rows = _rowsFromData(data, 'clinics');
      final frozen = rows.isNotEmpty && rows.first['frozen'] == true;
      if (frozen) {
        throw AccountFrozenException(accountId);
      }
    } catch (e) {
      if (e is AccountFrozenException) rethrow;
    }

    await ActiveAccountStore.writeAccountId(accountId);
    return ActiveAccount(id: accountId, role: role, canWrite: true);
  }

  Future<FeaturePermissions> fetchMyFeaturePermissions({
    required String accountId,
    FeaturePermissions? fallback,
  }) async {
    if (accountId.trim().isEmpty) {
      return FeaturePermissions.defaultsDenyAll();
    }

    try {
      final data = await _runQuery(
        '''
        query MyFeaturePermissions(\$account: uuid!) {
          my_feature_permissions(args: {p_account: \$account}) {
            allow_all
            allowed_features
            can_create
            can_update
            can_delete
          }
        }
        ''',
        {'account': accountId},
      );
      final rows = _rowsFromData(data, 'my_feature_permissions');
      if (rows.isEmpty) {
        return fallback ?? FeaturePermissions.defaultsDenyAll();
      }
      return FeaturePermissions.fromRpcPayload(rows.first);
    } catch (e, st) {
      throw FeaturePermissionsFetchException(
        message: 'fetchMyFeaturePermissions failed',
        fallback: fallback ?? FeaturePermissions.defaultsDenyAll(),
        cause: e,
        stackTrace: st,
      );
    }
  }

  // ───────────────────────── Sync bootstrap ─────────────────────────

  Future<void> bootstrapSyncForCurrentUser({
    bool pull = true,
    bool realtime = true,
    bool enableLogs = false,
    Duration debounce = const Duration(seconds: 1),
    bool wipeLocalFirst = false,
  }) async {
    final acc = await resolveActiveAccountOrThrow();
    final devId = await DeviceIdService.getId();
    final db = await DBService.instance.database;

    try {
      final lastAcc = await _readLastSyncedAccountId(db);
      final accountChangedBetweenLaunches =
          (lastAcc != null && lastAcc.isNotEmpty && lastAcc != acc.id);
      if (accountChangedBetweenLaunches) {
        dev.log(
          'Detected account change since last launch → clearing local tables.',
        );
        await DBService.instance.clearAllLocalTables();
      }
    } catch (e) {
      dev.log('read last sync_identity failed: $e');
    }

    if (_sync != null) {
      final accountChanged =
          (_boundAccountId != null && _boundAccountId != acc.id);
      if (wipeLocalFirst && accountChanged) {
        await DBService.instance.clearAllLocalTables();
      }
      await _disposeSync();
    }

    await _upsertSyncIdentity(db, accountId: acc.id, deviceId: devId);

    try {
      await DBParityV3().run(db, accountId: acc.id, verbose: enableLogs);
    } catch (e, st) {
      dev.log(
        'DBParityV3.run failed (continue anyway)',
        error: e,
        stackTrace: st,
      );
    }

    _sync = SyncService(
      db,
      acc.id,
      deviceId: devId,
      enableLogs: enableLogs,
      pushDebounce: debounce,
    );
    _boundAccountId = acc.id;

    _bindDbPush(_sync!);

    await _sync!.pushAll();
    await _sync!.bootstrap(pull: pull, realtime: realtime);
  }

  void _bindDbPush(SyncService sync) {
    DBService.instance.bindSyncPush(sync.pushFor);
  }

  Future<void> _disposeSync() async {
    final sync = _sync;
    if (sync == null) return;

    _sync = null;
    _boundAccountId = null;

    // فكّ الربط بين DBService و pushFor
    DBService.instance.onLocalChange = null;

    try {
      await sync.stopRealtime();
    } catch (_) {}

    // ✅ مهم: SyncService عندك يملك dispose() فعلياً
    try {
      await sync.dispose();
    } catch (_) {}
  }

  Future<void> _upsertSyncIdentity(
    dynamic db, {
    required String accountId,
    required String deviceId,
  }) async {
    try {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS sync_identity(account_id TEXT, device_id TEXT)',
      );
      await db.rawInsert(
        'INSERT INTO sync_identity(account_id, device_id) '
        'SELECT ?, ? WHERE NOT EXISTS(SELECT 1 FROM sync_identity)',
        [accountId, deviceId],
      );
      await db.rawUpdate(
        'UPDATE sync_identity SET account_id = ?, device_id = ?',
        [accountId, deviceId],
      );
    } catch (e) {
      dev.log('sync_identity write failed: $e');
    }
  }

  Future<String?> _readLastSyncedAccountId(dynamic db) async {
    try {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
        ['sync_identity'],
      );
      if (rows is List && rows.isNotEmpty) {
        final r =
            await db.rawQuery('SELECT account_id FROM sync_identity LIMIT 1');
        if (r is List && r.isNotEmpty) {
          final v = r.first['account_id']?.toString();
          return (v != null && v.isNotEmpty) ? v : null;
        }
      }
    } catch (e) {
      dev.log('_readLastSyncedAccountId failed: $e');
    }
    return null;
  }
}
