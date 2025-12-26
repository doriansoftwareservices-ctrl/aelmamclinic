// tool/sync_super_admins.dart
//
// Utility script that syncs the current AppConstants.superAdminEmails list
// into the Nhost/Hasura `public.super_admins` table by calling the
// `admin_sync_super_admin_emails` RPC via GraphQL using the admin secret.
//
// Usage:
//   flutter pub run tool/sync_super_admins.dart
//
// Required environment variables:
//   NHOST_GRAPHQL_URL           – GraphQL endpoint URL
//   HASURA_GRAPHQL_ADMIN_SECRET – admin secret with insert rights
//
// Optional:
//   none

import 'dart:convert';
import 'dart:io';

import 'package:aelmamclinic/core/constants.dart';
import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  await AppConstants.loadRuntimeOverrides();

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

  final emails = AppConstants.superAdminEmails
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();
  if (emails.isEmpty) {
    stdout.writeln(
      '[sync_super_admins] No super-admin emails configured. Nothing to sync.',
    );
    return;
  }

  final body = jsonEncode({
    'query': r'''
      mutation SyncSuperAdmins($emails: [String!]!) {
        admin_sync_super_admin_emails(args: {p_emails: $emails})
      }
    ''',
    'variables': {'emails': emails},
  });

  stdout.writeln(
    '[sync_super_admins] Syncing ${emails.length} super-admin email(s) → $graphqlUrl',
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
    stdout.writeln('[sync_super_admins] Sync completed successfully.');
    return;
  }

  stderr.writeln(
    '[sync_super_admins] Sync failed (${resp.statusCode}): ${resp.body}',
  );
  exit(1);
}
