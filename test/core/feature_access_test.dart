import 'package:flutter_test/flutter_test.dart';

import 'package:aelmamclinic/core/features.dart';

class _FakeAuth {
  final bool isSuperAdmin;
  bool permissionsLoaded;
  bool canCreate;
  bool canUpdate;
  bool canDelete;
  final bool Function(String key) featureAllowedHandler;

  _FakeAuth({
    this.permissionsLoaded = false,
    this.canCreate = false,
    this.canUpdate = false,
    this.canDelete = false,
    required this.featureAllowedHandler,
  }) : isSuperAdmin = false;

  bool featureAllowed(String key) => featureAllowedHandler(key);
}

void main() {
  test(
      'FeatureAccess denies access when permissions are not loaded even if featureAllowed returns true',
      () {
    final fakeAuth = _FakeAuth(
      permissionsLoaded: false,
      featureAllowedHandler: (_) => true,
    );

    final fx = FeatureAccess(fakeAuth as dynamic);
    final allowed = fx.allowed(FeatureKeys.dashboard);

    expect(allowed, isFalse);
  });

  test('FeatureAccess respects permissions when loaded', () {
    final fakeAuth = _FakeAuth(
      permissionsLoaded: true,
      canCreate: true,
      canUpdate: true,
      canDelete: true,
      featureAllowedHandler: (_) => true,
    );

    final fx = FeatureAccess(fakeAuth as dynamic);
    expect(fx.allowed(FeatureKeys.dashboard), isTrue);
  });
}
