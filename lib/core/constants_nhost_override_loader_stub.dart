import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

Future<
    ({
      String? nhostSubdomain,
      String? nhostRegion,
      String? nhostGraphqlUrl,
      String? nhostAuthUrl,
      String? nhostStorageUrl,
      String? nhostFunctionsUrl,
      String? resetPasswordRedirectUrl,
      String? rootSuperAdminEmail,
      String? source
})?> loadNhostRuntimeOverrides({
  required String windowsDataDir,
  required String legacyWindowsDataDir,
  required String linuxDataDir,
  required String macOsDataDir,
  required String androidDataDir,
  required String iosLogicalDataDir,
}) async {
  try {
    final raw = await rootBundle.loadString('assets/config.json');
    if (raw.trim().isEmpty) return null;

    final data = jsonDecode(raw);
    if (data is! Map) return null;

    String? readKey(String key) {
      final value = data[key] ?? data[lowerSnake(key)];
      if (value == null) return null;
      if (value is String) {
        return value.trim();
      }
      return '$value'.trim();
    }

    bool isValidSimpleToken(String? value) {
      if (value == null) return false;
      final trimmed = value.trim();
      if (trimmed.isEmpty || trimmed.contains(',') || trimmed.contains(' ')) {
        return false;
      }
      return RegExp(r'^[a-z0-9-]+$', caseSensitive: false).hasMatch(trimmed);
    }

    String? sanitizeUrl(String? value) {
      if (value == null) return null;
      final trimmed = value.trim();
      if (trimmed.isEmpty || trimmed.contains(',')) return null;
      final uri = Uri.tryParse(trimmed);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          !uri.host.contains('nhost.run')) {
        return null;
      }
      return trimmed;
    }

    final rawSubdomain = readKey('nhostSubdomain');
    final rawRegion = readKey('nhostRegion');
    final nhostSubdomain =
        isValidSimpleToken(rawSubdomain) ? rawSubdomain?.trim() : null;
    final nhostRegion =
        isValidSimpleToken(rawRegion) ? rawRegion?.trim() : null;
    final nhostGraphqlUrl = sanitizeUrl(readKey('nhostGraphqlUrl'));
    final nhostAuthUrl = sanitizeUrl(readKey('nhostAuthUrl'));
    final nhostStorageUrl = sanitizeUrl(readKey('nhostStorageUrl'));
    final nhostFunctionsUrl = sanitizeUrl(readKey('nhostFunctionsUrl'));
    final resetPasswordRedirectUrl = readKey('resetPasswordRedirectUrl');
    final rootSuperAdminEmail = readKey('rootSuperAdminEmail');

    bool isValidEmail(String? value) {
      if (value == null) return false;
      final trimmed = value.trim();
      if (trimmed.isEmpty) return false;
      return RegExp(r'^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$').hasMatch(trimmed);
    }

    final noNhostOverrides =
        (nhostSubdomain == null || nhostSubdomain.isEmpty) &&
            (nhostRegion == null || nhostRegion.isEmpty) &&
            (nhostGraphqlUrl == null || nhostGraphqlUrl.isEmpty) &&
            (nhostAuthUrl == null || nhostAuthUrl.isEmpty) &&
            (nhostStorageUrl == null || nhostStorageUrl.isEmpty) &&
            (nhostFunctionsUrl == null || nhostFunctionsUrl.isEmpty) &&
            (resetPasswordRedirectUrl == null ||
                resetPasswordRedirectUrl.isEmpty) &&
            (!isValidEmail(rootSuperAdminEmail));

    if (noNhostOverrides) {
      return null;
    }

    return (
      nhostSubdomain: nhostSubdomain,
      nhostRegion: nhostRegion,
      nhostGraphqlUrl: nhostGraphqlUrl,
      nhostAuthUrl: nhostAuthUrl,
      nhostStorageUrl: nhostStorageUrl,
      nhostFunctionsUrl: nhostFunctionsUrl,
      resetPasswordRedirectUrl: resetPasswordRedirectUrl,
      rootSuperAdminEmail:
          isValidEmail(rootSuperAdminEmail) ? rootSuperAdminEmail : null,
      source: 'assets/config.json',
    );
  } catch (_) {
    return null;
  }
}

String lowerSnake(String camel) {
  final buffer = StringBuffer();
  for (var i = 0; i < camel.length; i++) {
    final char = camel[i];
    final isUpper = char.toUpperCase() == char && char.toLowerCase() != char;
    if (isUpper && i > 0) {
      buffer.write('_');
    }
    buffer.write(char.toLowerCase());
  }
  return buffer.toString();
}
