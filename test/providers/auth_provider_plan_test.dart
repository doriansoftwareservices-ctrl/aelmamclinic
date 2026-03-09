import 'package:flutter_test/flutter_test.dart';
import 'package:nhost_dart/nhost_dart.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';
import 'package:aelmamclinic/services/nhost_auth_service.dart';

class _InMemoryAuthStore implements AuthStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> removeItem(String key) async {
    _values.remove(key);
  }
}

NhostClient _buildTestClient() {
  return NhostClient(
    serviceUrls: ServiceUrls(
      authUrl: 'https://example.com/v1/auth',
      graphqlUrl: 'https://example.com/v1/graphql',
      storageUrl: 'https://example.com/v1/storage',
      functionsUrl: 'https://example.com/v1/functions',
    ),
    authStore: _InMemoryAuthStore(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuthProvider auth;

  setUp(() {
    auth = AuthProvider(
      authService: NhostAuthService(client: _buildTestClient()),
      listenAuthChanges: false,
    );
  });

  tearDown(() {
    auth.dispose();
  });

  test('defaults to free plan when there is no current user', () {
    auth.debugSetCurrentUser(null);

    expect(auth.planCode, equals('free'));
    expect(auth.planEndAt, isNull);
    expect(auth.isPro, isFalse);
  });

  test('treats future paid plan as pro', () {
    final endAt = DateTime.now().add(const Duration(days: 30));
    auth.debugSetCurrentUser(<String, dynamic>{
      'planCode': 'YEAR',
      'planEndAt': endAt,
      'isSuperAdmin': false,
    });

    expect(auth.planCode, equals('year'));
    expect(auth.planEndAt, equals(endAt));
    expect(auth.isPro, isTrue);
  });

  test('treats expired paid plan as not pro', () {
    auth.debugSetCurrentUser(<String, dynamic>{
      'planCode': 'month',
      'planEndAt': DateTime.now().subtract(const Duration(days: 1)),
      'isSuperAdmin': false,
    });

    expect(auth.isPro, isFalse);
  });

  test('super admin remains pro even on free plan', () {
    auth.debugSetCurrentUser(<String, dynamic>{
      'planCode': 'free',
      'isSuperAdmin': true,
    });

    expect(auth.isSuperAdmin, isTrue);
    expect(auth.isPro, isTrue);
  });
}
