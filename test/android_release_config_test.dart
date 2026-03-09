import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final projectRoot = Directory.current.path;
  final buildGradle = File('$projectRoot/android/app/build.gradle.kts');
  final manifest = File('$projectRoot/android/app/src/main/AndroidManifest.xml');

  test('release build no longer falls back to debug signing', () async {
    final text = await buildGradle.readAsString();

    expect(text, isNot(contains('signingConfig = signingConfigs.getByName("debug")')));
    expect(text, contains('key.properties'));
    expect(text, contains('artifact غير موقّع'));
  });

  test('Android manifest scopes legacy storage permissions to old SDKs only', () async {
    final text = await manifest.readAsString();

    expect(text, contains('android.permission.READ_EXTERNAL_STORAGE'));
    expect(text, contains('android.permission.WRITE_EXTERNAL_STORAGE'));
    expect(text, contains('android:maxSdkVersion="28"'));
    expect(text, isNot(contains('requestLegacyExternalStorage="true"')));
  });
}
