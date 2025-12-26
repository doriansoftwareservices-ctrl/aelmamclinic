// tool/sync_super_admins.dart
//
// Utility script that syncs the configured super-admin emails list
// into the Nhost/Hasura `public.super_admins` table by calling the
// `admin_sync_super_admin_emails` RPC via GraphQL using the admin secret.
//
// Usage:
//   dart run tool/sync_super_admins.dart
//
// Required environment variables:
//   NHOST_GRAPHQL_URL           – GraphQL endpoint URL
//   HASURA_GRAPHQL_ADMIN_SECRET – admin secret with insert rights
//
// Optional:
//   none

import 'dart:convert';
import 'dart:io';

import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  final graphqlUrl =
      (Platform.environment['NHOST_GRAPHQL_URL'] ?? NhostConfig.graphqlUrl)
          .trim();
  if (graphqlUrl.isEmpty) {
    stderr.writeln(
        '[sync_super_admins] Missing Nhost GraphQL URL. Provide NHOST_GRAPHQL_URL or config override.');
    exit(64);
  }

  final adminSecret = Platform.environment['HASURA_GRAPHQL_ADMIN_SECRET'] ??
      Platform.environment['NHOST_ADMIN_SECRET'];
  if (adminSecret == null || adminSecret.trim().isEmpty) {
    stderr.writeln(
      '[sync_super_admins] Missing HASURA_GRAPHQL_ADMIN_SECRET / NHOST_ADMIN_SECRET.',
    );
    exit(64);
  }
  final adminSecretValue = adminSecret.trim();

  final emails = <String>{};
  final envEmails = _readEmailsFromEnv();
  if (envEmails.isNotEmpty) {
    emails.addAll(envEmails);
  }
  final configEmails = await _readEmailsFromConfig();
  if (configEmails.isNotEmpty) {
    emails.addAll(configEmails);
  }
  final list = emails
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();
  if (list.isEmpty) {
    stdout.writeln(
      '[sync_super_admins] No super-admin emails configured. Nothing to sync.',
    );
    return;
  }

  final body = jsonEncode({
    'query': r'''
      mutation SyncSuperAdmins($emails: [String!]!) {
        admin_sync_super_admin_emails_gql(args: {p_emails: $emails}) {
          ok
          error
        }
      }
    ''',
    'variables': {'emails': list},
  });

  stdout.writeln(
    '[sync_super_admins] Syncing ${list.length} super-admin email(s) → $graphqlUrl',
  );
  final resp = await http.post(
    Uri.parse(graphqlUrl),
    headers: {
      'x-hasura-admin-secret': adminSecretValue,
      'Authorization': 'Bearer $adminSecretValue',
      'Content-Type': 'application/json',
    },
    body: body,
  );

  if (resp.statusCode >= 200 && resp.statusCode < 300) {
    final decoded = jsonDecode(resp.body);
    final root = decoded is Map<String, dynamic> ? decoded : null;
    final errors = root?['errors'];
    if (errors is List && errors.isNotEmpty) {
      final msg = errors.map((e) => e['message']).join(' | ');
      stderr.writeln('[sync_super_admins] Sync failed (GraphQL): $msg');
      exit(1);
    }
    final data = root?['data'];
    final rows = data is Map<String, dynamic>
        ? data['admin_sync_super_admin_emails_gql']
        : null;
    if (rows is List && rows.isNotEmpty) {
      final ok = rows.first['ok'] == true;
      if (!ok) {
        final err = rows.first['error'];
        stderr.writeln('[sync_super_admins] Sync failed: ${err ?? 'unknown'}');
        exit(1);
      }
    }
    stdout.writeln('[sync_super_admins] Sync completed successfully.');
    return;
  }

  stderr.writeln(
    '[sync_super_admins] Sync failed (${resp.statusCode}): ${resp.body}',
  );
  exit(1);
}

List<String> _readEmailsFromEnv() {
  final raw = Platform.environment['SUPER_ADMIN_EMAILS'] ??
      Platform.environment['SUPERADMIN_EMAILS'] ??
      '';
  if (raw.trim().isEmpty) return const [];
  return raw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

Future<List<String>> _readEmailsFromConfig() async {
  final path = await _findConfigPath();
  if (path == null) return const [];
  try {
    final raw = await File(path).readAsString();
    if (raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const [];
    final rawEmails = decoded['superAdminEmails'] ??
        decoded['super_admin_emails'] ??
        decoded['superAdmins'] ??
        decoded['super_admins'];
    if (rawEmails == null) return const [];
    if (rawEmails is String) {
      final trimmed = rawEmails.trim();
      return trimmed.isEmpty ? const [] : [trimmed];
    }
    if (rawEmails is List) {
      return rawEmails
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  } catch (_) {
    return const [];
  }
}

Future<String?> _findConfigPath() async {
  final candidates = <String>{
    r'C:\aelmam_clinic\config.json',
    r'D:\aelmam_clinic\config.json',
    '${_expandHome(r"~/.aelmam_clinic")}/config.json',
    '${_expandHome(r"~/Library/Application Support/aelmam_clinic")}/config.json',
    r'/sdcard/Android/data/com.aelmam.clinic/files/config.json',
  };
  for (final path in candidates) {
    try {
      if (await File(path).exists()) return path;
    } catch (_) {}
  }
  return null;
}

String _expandHome(String value) {
  if (!value.startsWith('~')) return value;
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    return value.replaceFirst('~', '');
  }
  return value.replaceFirst('~', home);
}
