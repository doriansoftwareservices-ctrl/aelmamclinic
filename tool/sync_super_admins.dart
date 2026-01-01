// tool/sync_super_admins.dart
//
// Utility script that syncs super-admin emails (from env) into the
// Nhost/Hasura `public.super_admins` table by calling the
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

  final emailsLiteral = _toPgTextArrayLiteral(list);
  final body = jsonEncode({
    'query': r'''
      mutation SyncSuperAdmins($emails: _text!) {
        admin_sync_super_admin_emails_gql(args: {p_emails: $emails}) {
          ok
          error
        }
      }
    ''',
    'variables': {'emails': emailsLiteral},
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

String _toPgTextArrayLiteral(List<String> values) {
  if (values.isEmpty) return '{}';
  final parts = values.map((value) {
    final escaped =
        value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }).join(',');
  return '{${parts}}';
}
