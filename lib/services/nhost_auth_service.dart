import 'dart:async';
import 'dart:developer' as dev;

import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:nhost_dart/nhost_dart.dart';
import 'package:nhost_sdk/nhost_sdk.dart' show AuthResponse, User;

import 'package:aelmamclinic/core/active_account_store.dart';
import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/nhost_manager.dart';
import 'package:aelmamclinic/services/network_status_service.dart';
import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:aelmamclinic/models/account_policy.dart';
import 'package:aelmamclinic/models/backend_errors.dart';
import 'package:aelmamclinic/models/clinic_profile.dart';
import 'package:aelmamclinic/models/feature_permissions.dart';
import 'package:aelmamclinic/services/db_parity_v3.dart';
import 'package:aelmamclinic/services/db_service.dart';
import 'package:aelmamclinic/services/device_id_service.dart';
import 'package:aelmamclinic/services/nhost_api_client.dart';
import 'package:aelmamclinic/services/nhost_graphql_service.dart';
import 'package:aelmamclinic/services/sync_service.dart';

/// مصادقة Nhost مع ربط المزامنة المحلية وحراسة الحساب.
/// توفر عمليات الدخول والخروج ومراقبة حالة الجلسة باستخدام `nhost_dart`.
class NhostAuthService {
  NhostAuthService({NhostClient? client, GraphQLClient? gql})
    : _client = client ?? NhostManager.client,
      _gqlOverride = gql {
    _authUnsub = _client.auth.addAuthStateChangedCallback((state) {
      NhostGraphqlService.refreshClient(client: _client);
      _authStateController.add(state);
      if (state == AuthenticationState.signedOut) {
        unawaited(_disposeSync());
      }
    });
  }

  final NhostClient _client;
  final GraphQLClient? _gqlOverride;
  final StreamController<AuthenticationState> _authStateController =
      StreamController.broadcast();
  UnsubscribeDelegate? _authUnsub;

  SyncService? _sync;
  String? _boundAccountId;
  String? _boundDeviceId;
  static const Duration _kGraphqlTimeout = Duration(seconds: 20);

  NhostClient get client => _client;
  SyncService? get sync => _sync;

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
    DBService.instance.clearCachedSyncIdentity();
    await _disposeSync();
  }

  Future<void> pauseSync() async {
    await _sync?.pauseSync();
  }

  Future<void> resumeSync() async {
    await _sync?.resumeSync();
  }

  Future<void> suspendRuntimeBindings() async {
    DBService.instance.clearCachedSyncIdentity();
    await _disposeSync();
  }

  Future<void> waitForSyncIdle({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await _sync?.waitForIdle(timeout: timeout);
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
    if (refreshToken == null || refreshToken.isEmpty) {
      // عند إعادة فتح التطبيق، قد لا تكون الجلسة محمّلة بعد.
      // استخدم AuthStore لاستعادة الجلسة إن أمكن.
      await _client.auth.signInWithStoredCredentials();
      return;
    }
    await _client.auth.signInWithRefreshToken(refreshToken);
  }

  /// يحاول استعادة الجلسة من التخزين المحلي فقط (بدون اشتراط اتصال).
  Future<void> restoreSessionLocal() async {
    await _client.auth.signInWithStoredCredentials();
  }

  Future<void> dispose() async {
    _authUnsub?.call();
    await _disposeSync();
    await _authStateController.close();
  }

  // ───────────────────────── GraphQL helpers ─────────────────────────

  GraphQLClient get _gql => _gqlOverride ?? NhostGraphqlService.client;

  String _sessionSnapshotQuery({required bool includeSuperFlag}) {
    final superField = includeSuperFlag
        ? '''
          fn_is_super_admin_gql {
            is_super_admin
          }
        '''
        : '';
    return '''
      query SessionSnapshot(\$uid: uuid!) {
        my_profile {
          account_id
          role
          chat_code
        }
        account_users(
          where: {user_uid: {_eq: \$uid}}
          order_by: {created_at: desc}
          limit: 1
        ) {
          account_id
          role
          disabled
        }
        my_account_plan {
          plan_code
          plan_end_at
        }
        $superField
      }
    ''';
  }

  Future<Map<String, dynamic>?> _fetchSessionSnapshot(
    String uid, {
    bool allowAuthRecovery = true,
  }) async {
    final includeSuper = _superAdminQuerySupported != false;
    try {
      final data = await _runQuery(
        _sessionSnapshotQuery(includeSuperFlag: includeSuper),
        {'uid': uid},
      );
      return data;
    } on BackendSchemaException {
      _superAdminQuerySupported = false;
      try {
        final data = await _runQuery(
          _sessionSnapshotQuery(includeSuperFlag: false),
          {'uid': uid},
        );
        return data;
      } catch (error) {
        if (allowAuthRecovery && _isAuthGraphqlError(error)) {
          final recovered = await _tryRecoverAuthSession();
          if (recovered) {
            return _fetchSessionSnapshot(uid, allowAuthRecovery: false);
          }
        }
        return null;
      }
    } catch (error) {
      if (allowAuthRecovery && _isAuthGraphqlError(error)) {
        final recovered = await _tryRecoverAuthSession();
        if (recovered) {
          return _fetchSessionSnapshot(uid, allowAuthRecovery: false);
        }
      }
      return null;
    }
  }

  Future<Map<String, dynamic>> _runQuery(
    String doc,
    Map<String, dynamic> variables,
  ) async {
    final safeVariables = Map<String, dynamic>.from(variables);
    final result = await _gql
        .query(
          QueryOptions(
            document: gql(doc),
            variables: safeVariables,
            fetchPolicy: FetchPolicy.noCache,
          ),
        )
        .timeout(_kGraphqlTimeout);
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
    Map<String, dynamic> variables, {
    String? role,
  }) async {
    final safeVariables = Map<String, dynamic>.from(variables);
    final result = await _gql
        .mutate(
          MutationOptions(
            document: gql(doc),
            variables: safeVariables,
            fetchPolicy: FetchPolicy.noCache,
            context: (role == null || role.trim().isEmpty)
                ? Context()
                : Context.fromList([
                    HttpLinkHeaders(headers: {'x-hasura-role': role.trim()}),
                  ]),
          ),
        )
        .timeout(_kGraphqlTimeout);
    if (result.hasException) {
      final ex = result.exception!;
      if (_isSchemaError(ex)) {
        throw BackendSchemaException(_formatOperationException(ex));
      }
      throw ex;
    }
    return result.data ?? <String, dynamic>{};
  }

  bool _isTransientGraphqlError(Object error) {
    if (error is TimeoutException) return true;
    final msg = error.toString().toLowerCase();
    return msg.contains('timeout') ||
        msg.contains('timed out') ||
        msg.contains('no stream event') ||
        msg.contains('503') ||
        msg.contains('bad gateway') ||
        msg.contains('service temporarily unavailable') ||
        msg.contains('connection');
  }

  bool _isNoMutationsGraphqlError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('no mutations exist') ||
        msg.contains('mutation_root') && msg.contains('not found') ||
        msg.contains('mutation') && msg.contains('validation-failed');
  }

  bool _isAuthGraphqlError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('401') ||
        msg.contains('403') ||
        msg.contains('unauthorized') ||
        msg.contains('access-denied') ||
        msg.contains('invalid_request') ||
        (msg.contains('jwt') && msg.contains('expired')) ||
        (msg.contains('access token') && msg.contains('expired'));
  }

  Future<bool> _tryRecoverAuthSession() async {
    try {
      await refreshSession();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isLegacySelfCreateAccountSignatureError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('p_city_ar') ||
        msg.contains('non default arguments cannot be omitted') ||
        (msg.contains('self_create_account') &&
            msg.contains('args.args') &&
            msg.contains('not-supported')) ||
        msg.contains('p_street_ar') ||
        msg.contains('p_near_ar') ||
        msg.contains('p_clinic_name_en') ||
        msg.contains('p_city_en') ||
        msg.contains('p_street_en') ||
        msg.contains('p_near_en') ||
        msg.contains('p_phone');
  }

  List<String> _orderedSessionRoles(List<String> preferredRoles) {
    final user = currentUser;
    final sessionRoles = <String>{
      ...preferredRoles.map((e) => e.toLowerCase().trim()),
      ...(user?.roles ?? const <String>[]).map((e) => e.toLowerCase().trim()),
      (user?.defaultRole ?? '').toLowerCase().trim(),
    };
    sessionRoles.removeWhere((role) => role.isEmpty);

    final ordered = <String>[];
    for (final role in preferredRoles.map((e) => e.toLowerCase().trim())) {
      if (sessionRoles.remove(role)) {
        ordered.add(role);
      }
    }
    ordered.addAll(sessionRoles);
    return ordered;
  }

  Future<Map<String, dynamic>> _runMutationWithRoleFallback(
    String doc,
    Map<String, dynamic> variables, {
    required List<String> preferredRoles,
  }) async {
    Object? lastError;
    for (final role in _orderedSessionRoles(preferredRoles)) {
      try {
        return await _runMutation(doc, variables, role: role);
      } catch (e) {
        lastError = e;
        if (_isNoMutationsGraphqlError(e)) {
          continue;
        }
        rethrow;
      }
    }
    if (lastError != null) {
      throw lastError;
    }
    return await _runMutation(doc, variables);
  }

  Future<Map<String, dynamic>> _runMutationWithAuthRecovery(
    String doc,
    Map<String, dynamic> variables, {
    required List<String> preferredRoles,
  }) async {
    try {
      return await _runMutation(doc, variables);
    } catch (e) {
      if (_isNoMutationsGraphqlError(e)) {
        try {
          await refreshSession();
        } catch (_) {}
        return await _runMutationWithRoleFallback(
          doc,
          variables,
          preferredRoles: preferredRoles,
        );
      }
      if (_isAuthGraphqlError(e)) {
        final recovered = await _tryRecoverAuthSession();
        if (recovered) {
          return await _runMutationWithRoleFallback(
            doc,
            variables,
            preferredRoles: preferredRoles,
          );
        }
      }
      rethrow;
    }
  }

  Uri _functionUri(String path) {
    final base = NhostConfig.functionsUrl.replaceAll(RegExp(r'/+$'), '');
    final cleanPath = path.replaceFirst(RegExp(r'^/+'), '');
    return Uri.parse('$base/$cleanPath');
  }

  bool _hasCompleteClinicProfile(ClinicProfileInput profile) {
    return profile.nameAr.trim().isNotEmpty &&
        profile.cityAr.trim().isNotEmpty &&
        profile.streetAr.trim().isNotEmpty &&
        profile.nearAr.trim().isNotEmpty &&
        profile.nameEn.trim().isNotEmpty &&
        profile.cityEn.trim().isNotEmpty &&
        profile.streetEn.trim().isNotEmpty &&
        profile.nearEn.trim().isNotEmpty &&
        profile.phone.trim().isNotEmpty;
  }

  Future<String> _selfCreateAccountViaFunction({
    required ClinicProfileInput profile,
  }) async {
    final api = NhostApiClient();
    try {
      final data = await api
          .postJson(_functionUri('self-create-owner'), <String, dynamic>{
            'clinic_name': profile.nameAr.trim(),
            'city_ar': profile.cityAr.trim(),
            'street_ar': profile.streetAr.trim(),
            'near_ar': profile.nearAr.trim(),
            'name_en': profile.nameEn.trim(),
            'city_en': profile.cityEn.trim(),
            'street_en': profile.streetEn.trim(),
            'near_en': profile.nearEn.trim(),
            'phone': profile.phone.trim(),
            'phone2': (profile.phone2 ?? '').trim().isEmpty
                ? null
                : profile.phone2!.trim(),
          });
      final ok = data['ok'] == true;
      final accountId = '${data['account_id'] ?? ''}'.trim();
      if (!ok || accountId.isEmpty) {
        final message = '${data['error'] ?? 'self-create-owner failed'}'.trim();
        throw StateError(
          message.isEmpty ? 'self-create-owner failed' : message,
        );
      }
      return accountId;
    } finally {
      api.dispose();
    }
  }

  Future<void> _refreshSessionAfterAccountMutation() async {
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        await refreshSession();
        return;
      } catch (_) {
        if (attempt >= 2) return;
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
      }
    }
  }

  String _requireCreatedAccountId(List<Map<String, dynamic>> rows) {
    final accountId = rows.isEmpty
        ? ''
        : (rows.first['id']?.toString() ?? '').trim();
    if (accountId.isEmpty) {
      throw StateError('self_create_account returned empty account id');
    }
    return accountId;
  }

  Future<void> _finalizeSelfCreateAccount({
    required ClinicProfileInput profile,
  }) async {
    await _refreshSessionAfterAccountMutation();
    if (!_hasCompleteClinicProfile(profile)) {
      return;
    }
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 4; attempt += 1) {
      try {
        await updateClinicProfile(profile: profile);
        return;
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;
        if (attempt >= 3) {
          dev.log(
            'self_create_account completed but update_clinic_profile still failed',
            name: 'AUTH',
            error: e,
            stackTrace: st,
          );
          return;
        }
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
        await _refreshSessionAfterAccountMutation();
      }
    }
    if (lastError != null) {
      dev.log(
        'self_create_account finalized with deferred clinic profile update',
        name: 'AUTH',
        error: lastError,
        stackTrace: lastStackTrace,
      );
    }
  }

  Future<String> selfCreateAccount({
    required ClinicProfileInput profile,
  }) async {
    if (_hasCompleteClinicProfile(profile)) {
      try {
        final accountId = await _selfCreateAccountViaFunction(
          profile: profile,
        );
        await _finalizeSelfCreateAccount(profile: profile);
        return accountId;
      } catch (functionError, functionStack) {
        dev.log(
          'self-create-owner function failed; falling back to GraphQL RPC',
          name: 'AUTH',
          error: functionError,
          stackTrace: functionStack,
        );
        try {
          await _refreshSessionAfterAccountMutation();
          final active = await resolveActiveAccountOrThrow();
          if (active.id.trim().isNotEmpty &&
              (active.role.toLowerCase() == 'owner' ||
                  active.role.toLowerCase() == 'admin')) {
            await _finalizeSelfCreateAccount(profile: profile);
            return active.id;
          }
        } catch (_) {}
      }
    }

    const modernMutation = r'''
      mutation SelfCreateAccountModern($clinic_name: String!) {
        self_create_account(
          args: {
            p_clinic_name: $clinic_name
          }
        ) {
          id
        }
      }
    ''';
    const legacyMutation = r'''
      mutation SelfCreateAccountLegacy(
        $name_ar: String!
        $city_ar: String!
        $street_ar: String!
        $near_ar: String!
        $name_en: String!
        $city_en: String!
        $street_en: String!
        $near_en: String!
        $phone: String!
        $phone2: String
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
            p_phone2: $phone2
          }
        ) {
          id
        }
      }
    ''';
    final legacyVars = <String, dynamic>{
      'name_ar': profile.nameAr.trim(),
      'city_ar': profile.cityAr.trim(),
      'street_ar': profile.streetAr.trim(),
      'near_ar': profile.nearAr.trim(),
      'name_en': profile.nameEn.trim(),
      'city_en': profile.cityEn.trim(),
      'street_en': profile.streetEn.trim(),
      'near_en': profile.nearEn.trim(),
      'phone': profile.phone.trim(),
      'phone2': (profile.phone2 ?? '').trim().isEmpty
          ? null
          : profile.phone2!.trim(),
    };
    final modernVars = <String, dynamic>{'clinic_name': profile.nameAr.trim()};
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        final data = await _runMutationWithAuthRecovery(
          modernMutation,
          modernVars,
          preferredRoles: const ['user', 'me'],
        );
        final rows = _rowsFromData(data, 'self_create_account');
        final accountId = _requireCreatedAccountId(rows);
        await _finalizeSelfCreateAccount(profile: profile);
        return accountId;
      } catch (e) {
        if (_isLegacySelfCreateAccountSignatureError(e)) {
          try {
            final data = await _runMutationWithAuthRecovery(
              legacyMutation,
              legacyVars,
              preferredRoles: const ['user', 'me'],
            );
            final rows = _rowsFromData(data, 'self_create_account');
            final accountId = _requireCreatedAccountId(rows);
            await _finalizeSelfCreateAccount(profile: profile);
            return accountId;
          } catch (legacyError) {
            if (_isNoMutationsGraphqlError(legacyError)) {
              final accountId = await _selfCreateAccountViaFunction(
                profile: profile,
              );
              await _finalizeSelfCreateAccount(profile: profile);
              return accountId;
            }
            rethrow;
          }
        }
        if (_isNoMutationsGraphqlError(e)) {
          final accountId = await _selfCreateAccountViaFunction(
            profile: profile,
          );
          await _finalizeSelfCreateAccount(profile: profile);
          return accountId;
        }
        if (attempt == 0 && _isTransientGraphqlError(e)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        rethrow;
      }
    }
    return '';
  }

  Future<Map<String, dynamic>?> fetchClinicProfile({
    required String accountId,
  }) async {
    if (accountId.trim().isEmpty) return null;
    final data = await _runQuery(
      r'''
      query ClinicProfile($id: uuid!) {
        accounts(where: {id: {_eq: $id}}, limit: 1) {
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
          phone2
        }
      }
      ''',
      {'id': accountId},
    );
    final rows = _rowsFromData(data, 'accounts');
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> updateClinicProfile({
    required ClinicProfileInput profile,
  }) async {
    if (!_hasCompleteClinicProfile(profile)) {
      return;
    }
    const mutation = r'''
      mutation UpdateClinicProfile(
        $name_ar: String!
        $city_ar: String!
        $street_ar: String!
        $near_ar: String!
        $name_en: String!
        $city_en: String!
        $street_en: String!
        $near_en: String!
        $phone: String!
        $phone2: String
      ) {
        update_clinic_profile(
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
            p_phone2: $phone2
          }
        ) {
          ok
          error
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
      'phone2': (profile.phone2 ?? '').trim().isEmpty
          ? null
          : profile.phone2!.trim(),
    };
    final data = await _runMutationWithAuthRecovery(
      mutation,
      vars,
      preferredRoles: const ['user', 'me', 'owner'],
    );
    final rows = _rowsFromData(data, 'update_clinic_profile');
    final ok = rows.isNotEmpty ? rows.first['ok'] == true : false;
    if (!ok) {
      final err = rows.isNotEmpty ? rows.first['error']?.toString() : null;
      throw Exception(err ?? 'update_clinic_profile failed');
    }
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
      final data = await _runQuery('''
        query MyProfile {
          my_profile {
            id
            email
            account_id
            role
          }
        }
        ''', const {});
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
      final data = await _runQuery('''
        query MyAccountPlan {
          my_account_plan {
            plan_code
          }
        }
        ''', const {});
      final rows = _rowsFromData(data, 'my_account_plan');
      if (rows.isEmpty) return null;
      return rows.first['plan_code']?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchMyPlanDetails() async {
    try {
      final data = await _runQuery('''
        query MyAccountPlanDetails {
          my_account_plan {
            plan_code
            plan_end_at
          }
        }
        ''', const {});
      final rows = _rowsFromData(data, 'my_account_plan');
      if (rows.isEmpty) return null;
      return rows.first;
    } catch (_) {
      return null;
    }
  }

  bool _isSchemaError(OperationException ex) {
    final message = _formatOperationException(ex);
    final lower = message.toLowerCase();
    return lower.contains('not found in type') ||
        lower.contains('field') && lower.contains('not found') ||
        lower.contains('does not exist') && lower.contains('relation');
  }

  String _formatOperationException(OperationException ex) {
    if (ex.graphqlErrors.isEmpty) {
      return ex.toString();
    }
    return ex.graphqlErrors.map((e) => e.message).join(' | ');
  }

  static bool? _superAdminQuerySupported;

  Future<bool> _resolveSuperAdminFlag({String? fallbackEmail}) async {
    if (_superAdminQuerySupported == false) return false;
    const query = 'query { fn_is_super_admin_gql { is_super_admin } }';
    try {
      final data = await _runQuery(query, const {});
      _superAdminQuerySupported = true;
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
      if (e is BackendSchemaException) {
        _superAdminQuerySupported = false;
        dev.log(
          'fn_is_super_admin_gql missing; skipping super admin DB check',
          name: 'AUTH',
        );
        return false;
      }
      if (e is TimeoutException) {
        _superAdminQuerySupported = false;
        dev.log(
          'fn_is_super_admin_gql timeout; skipping super admin DB check',
          name: 'AUTH',
        );
        return false;
      }
      if (e is OperationException && _isSchemaError(e)) {
        _superAdminQuerySupported = false;
        dev.log(
          'fn_is_super_admin_gql not available; skipping super admin DB check',
          name: 'AUTH',
        );
        return false;
      }
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
    String? planCode;
    DateTime? planEndAt;
    bool? dbIsSuper;

    final snap = await _fetchSessionSnapshot(user.id);
    if (snap != null && snap.isNotEmpty) {
      final profileRows = _rowsFromData(snap, 'my_profile');
      if (profileRows.isNotEmpty) {
        final profile = profileRows.first;
        final profileAccount = profile['account_id']?.toString();
        if (profileAccount != null &&
            profileAccount.isNotEmpty &&
            profileAccount != 'null') {
          accountId = profileAccount;
          await ActiveAccountStore.writeAccountId(profileAccount);
        }
        role = profile['role']?.toString();
        final code = profile['chat_code']?.toString();
        if (code != null && code.isNotEmpty) {
          // stash for AuthProvider
          snap['__chat_code'] = code;
        }
      }

      final accountRows = _rowsFromData(snap, 'account_users');
      if (accountRows.isNotEmpty) {
        final row = accountRows.first;
        accountId ??= row['account_id']?.toString();
        role ??= row['role']?.toString();
        disabled = row['disabled'] == true;
        if (accountId != null && accountId.isNotEmpty) {
          await ActiveAccountStore.writeAccountId(accountId);
        }
      }

      final planRows = _rowsFromData(snap, 'my_account_plan');
      if (planRows.isNotEmpty) {
        planCode = planRows.first['plan_code']?.toString();
        final rawEnd = planRows.first['plan_end_at']?.toString();
        if (rawEnd != null && rawEnd.isNotEmpty) {
          planEndAt = DateTime.tryParse(rawEnd);
        }
      }

      final superRows = _rowsFromData(snap, 'fn_is_super_admin_gql');
      if (superRows.isNotEmpty) {
        final flag = superRows.first['is_super_admin'];
        if (flag is bool) {
          dbIsSuper = flag;
        }
      }
    }

    if (snap == null) {
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
        final row =
            await _fetchAccountUserRow(uid: user.id, accountId: preferred) ??
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
    }

    final tokenRoles = user.roles.map((r) => r.toLowerCase()).toList();
    final tokenIsSuper =
        tokenRoles.contains('superadmin') ||
        (user.defaultRole.toLowerCase() == 'superadmin');
    final metaRole =
        (user.metadata?['role']?.toString().toLowerCase() == 'superadmin');
    if (tokenIsSuper && _superAdminQuerySupported != false) {
      dbIsSuper ??= await _resolveSuperAdminFlag(fallbackEmail: user.email);
    }
    final emailLower = (user.email ?? '').toLowerCase().trim();
    final rootEmail = NhostConfig.rootSuperAdminEmail.toLowerCase().trim();
    final isSuper =
        tokenIsSuper &&
        (dbIsSuper == true ||
            _superAdminQuerySupported == false ||
            metaRole ||
            (emailLower == rootEmail));

    final chatCode = snap?['__chat_code']?.toString();
    if (dbIsSuper == true && !tokenIsSuper) {
      dev.log(
        'User is super admin in DB but token lacks superadmin role; treating as non-superadmin until role is synced.',
        name: 'AUTH',
      );
    }
    if (planCode == null) {
      try {
        final details = await fetchMyPlanDetails();
        planCode = details?['plan_code']?.toString() ?? 'free';
        if (planEndAt == null) {
          final rawEnd = details?['plan_end_at']?.toString();
          if (rawEnd != null && rawEnd.isNotEmpty) {
            planEndAt = DateTime.tryParse(rawEnd);
          }
        }
      } catch (_) {}
    }

    return {
      'uid': user.id,
      'email': user.email,
      'accountId': accountId,
      'role': role,
      'disabled': disabled,
      'isSuperAdmin': isSuper,
      'planCode': planCode,
      'planEndAt': planEndAt,
      if (chatCode != null && chatCode.isNotEmpty) 'chatCode': chatCode,
    };
  }

  Future<ActiveAccount> resolveActiveAccountOrThrowFromCache({
    required String uid,
    String? accountId,
    String? role,
    bool disabled = false,
    String? planCode,
  }) async {
    if (accountId == null ||
        accountId.isEmpty ||
        role == null ||
        role.isEmpty) {
      return resolveActiveAccountOrThrow();
    }

    if (disabled) {
      throw AccountUserDisabledException(accountId);
    }

    final roleLower = role.toLowerCase();
    String effectivePlan = (planCode ?? '').toLowerCase();
    if (effectivePlan.isEmpty) {
      try {
        effectivePlan = (await fetchMyPlanCode() ?? 'free').toLowerCase();
      } catch (_) {
        effectivePlan = 'free';
      }
    }
    if (effectivePlan == 'free' &&
        roleLower != 'owner' &&
        roleLower != 'admin' &&
        roleLower != 'superadmin') {
      throw PlanUpgradeRequiredException(accountId, planCode: effectivePlan);
    }

    try {
      final data = await _runQuery(
        r'''
        query ClinicFrozen($id: uuid!) {
          clinics(where: {id: {_eq: $id}}, limit: 1) {
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
      final data = await _runQuery(
        'query { my_account_id { account_id } }',
        const {},
      );
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
    String? profileAccountId;
    String? profileRoleName;
    String role = 'employee';
    bool roleResolved = false;
    bool disabled = false;
    String planCode = 'free';

    try {
      final profile = await _fetchMyProfileRow();
      if (profile != null) {
        final pa = profile['account_id']?.toString();
        if (pa != null && pa.isNotEmpty && pa != 'null') {
          profileAccountId = pa;
        }
        final pr = (profile['role'] as String?)?.trim();
        if (pr != null && pr.isNotEmpty) {
          profileRoleName = pr;
        }
      }
    } catch (_) {}

    try {
      final preferred = await ActiveAccountStore.readAccountId();
      final rowPreferred = await _fetchAccountUserRow(
        uid: user.id,
        accountId: preferred,
      );
      final row = rowPreferred ?? await _fetchAccountUserRow(uid: user.id);
      if (row != null) {
        accountId = row['account_id']?.toString();
        final rowRole = (row['role'] as String?)?.trim();
        if (rowRole != null && rowRole.isNotEmpty) {
          role = rowRole;
          roleResolved = true;
        }
        disabled = row['disabled'] == true;
      } else if (profileAccountId != null) {
        accountId = profileAccountId;
        if (profileRoleName != null && profileRoleName.isNotEmpty) {
          role = profileRoleName;
          roleResolved = true;
        }
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

    if (_sync != null && _boundAccountId == acc.id && _boundDeviceId == devId) {
      final sync = _sync!;
      _bindDbPush(sync);
      DBService.instance.setCachedSyncIdentity(
        accountId: acc.id,
        deviceId: devId,
      );
      await sync.bootstrap(pull: pull, realtime: realtime);
      await _flushLocalChangesIfNeeded(sync, initialPullAlreadyDone: pull);
      return;
    }

    try {
      final lastAcc = await _readLastSyncedAccountId(db);
      final accountChangedBetweenLaunches =
          (lastAcc != null && lastAcc.isNotEmpty && lastAcc != acc.id);
      if (accountChangedBetweenLaunches) {
        final hasForeignRows = await DBService.instance.hasRowsForOtherAccount(
          acc.id,
        );
        if (hasForeignRows) {
          dev.log(
            'Account change detected → pending local wipe (manual confirmation required).',
          );
          await ActiveAccountStore.setPendingWipe(acc.id);
          DBService.instance.clearCachedSyncIdentity();
          await _disposeSync();
          return;
        } else {
          dev.log(
            'Account change detected but no foreign-account rows found → skip local wipe.',
          );
        }
      }
    } catch (e) {
      dev.log('read last sync_identity failed: $e');
    }

    if (_sync != null) {
      final accountChanged =
          (_boundAccountId != null && _boundAccountId != acc.id);
      if (wipeLocalFirst && accountChanged) {
        dev.log(
          'wipeLocalFirst requested → pending local wipe (manual confirmation required).',
        );
        await ActiveAccountStore.setPendingWipe(acc.id);
        DBService.instance.clearCachedSyncIdentity();
        await _disposeSync();
        return;
      }
      await _disposeSync();
    }

    await _upsertSyncIdentity(db, accountId: acc.id, deviceId: devId);
    DBService.instance.setCachedSyncIdentity(
      accountId: acc.id,
      deviceId: devId,
    );

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
      canSync: _canSyncGuard,
    );
    _boundAccountId = acc.id;
    _boundDeviceId = devId;

    final sync = _sync;
    if (sync != null) {
      _bindDbPush(sync);
      await sync.bootstrap(pull: pull, realtime: realtime);
      await _flushLocalChangesIfNeeded(sync, initialPullAlreadyDone: pull);
    }
  }

  Future<bool> _canSyncGuard() async {
    if (!NetworkStatusService.instance.isOnline) return false;
    final user = _client.auth.currentUser;
    if (user == null) return false;
    final accId = _boundAccountId ?? await resolveAccountId();
    if (accId == null || accId.trim().isEmpty) return false;
    try {
      final data = await _runQuery(
        r'''
        query SyncGuard($uid: uuid!, $acc: uuid!) {
          account_users(
            where: {user_uid: {_eq: $uid}, account_id: {_eq: $acc}}
            limit: 1
          ) {
            disabled
          }
          clinics(where: {id: {_eq: $acc}}, limit: 1) {
            frozen
          }
        }
        ''',
        {'uid': user.id, 'acc': accId},
      );
      final users = _rowsFromData(data, 'account_users');
      if (users.isEmpty) return false;
      final disabled = users.first['disabled'] == true;
      if (disabled) return false;
      final clinics = _rowsFromData(data, 'clinics');
      final frozen = clinics.isNotEmpty && clinics.first['frozen'] == true;
      if (frozen) return false;
      return true;
    } catch (_) {
      // لا نعطّل المزامنة بسبب خطأ شبكة/تذبذب مؤقت
      return true;
    }
  }

  void _bindDbPush(SyncService sync) {
    DBService.instance.bindSyncPush(sync.pushFor);
  }

  Future<void> _disposeSync() async {
    final sync = _sync;
    if (sync == null) return;
    _sync = null;
    _boundAccountId = null;
    _boundDeviceId = null;
    DBService.instance.onLocalChange = null;
    try {
      await sync.dispose();
    } catch (_) {}
  }

  Future<void> _flushLocalChangesIfNeeded(
    SyncService sync, {
    required bool initialPullAlreadyDone,
  }) async {
    final dirty = await DBService.instance.getDirtySyncTables();
    if (dirty.isEmpty) return;
    await sync.pushAll();
    if (initialPullAlreadyDone || dirty.isNotEmpty) {
      await sync.pullAll(reason: 'bootstrap_dirty_flush');
    }
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
        final r = await db.rawQuery(
          'SELECT account_id FROM sync_identity LIMIT 1',
        );
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
