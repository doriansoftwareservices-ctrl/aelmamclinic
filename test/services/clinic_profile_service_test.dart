import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aelmamclinic/services/clinic_profile_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('isPaidPlan returns false when no cached plan exists', () async {
    expect(await ClinicProfileService.isPaidPlan(), isFalse);
  });

  test('isPaidPlan returns false for free plan', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth.planCode': 'free',
    });

    expect(await ClinicProfileService.isPaidPlan(), isFalse);
  });

  test('isPaidPlan returns true for paid plans', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth.planCode': 'YEAR',
    });

    expect(await ClinicProfileService.isPaidPlan(), isTrue);
  });
}
