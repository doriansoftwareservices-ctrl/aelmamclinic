// tool/sync_super_admins.dart
//
// Utility script that syncs the current AppConstants.superAdminEmails list
// into the Supabase `public.super_admins` table by calling the
// `admin_sync_super_admin_emails` RPC using the service role key.
//
// Usage:
//   flutter pub run tool/sync_super_admins.dart
//
// Required environment variables:
//   SUPABASE_URL                – Supabase project URL
//   SUPABASE_SERVICE_ROLE_KEY   – service role key with insert rights
//
// Optional:
//   SUPABASE_ANON_KEY / --dart-define overrides handled by AppConstants

import 'dart:convert';
import 'dart:io';

import 'package:aelmamclinic/core/constants.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  await AppConstants.loadRuntimeOverrides();

  final supabaseUrl = AppConstants.supabaseUrl.trim();
  if (supabaseUrl.isEmpty) {
    stderr.writeln(
        '[sync_super_admins] Missing Supabase URL. Provide --dart-define SUPABASE_URL or config override.');
    exit(64);
  }

  final serviceKey = Platform.environment['SUPABASE_SERVICE_ROLE_KEY'] ??
      Platform.environment['SERVICE_ROLE_KEY'] ??
      '';
  if (serviceKey.isEmpty) {
    stderr.writeln(
        '[sync_super_admins] Missing SUPABASE_SERVICE_ROLE_KEY / SERVICE_ROLE_KEY environment variable.');
    exit(64);
  }

  final emails = AppConstants.superAdminEmails
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();
  if (emails.isEmpty) {
    stdout.writeln(
        '[sync_super_admins] No super-admin emails configured. Nothing to sync.');
    return;
  }

  final rpcUrl = _buildRpcUrl(supabaseUrl, 'admin_sync_super_admin_emails');
  final body = jsonEncode({'p_emails': emails});

  stdout.writeln(
      '[sync_super_admins] Syncing ${emails.length} super-admin email(s) → $rpcUrl');
  final resp = await http.post(
    rpcUrl,
    headers: {
      'apikey': serviceKey,
      'Authorization': 'Bearer $serviceKey',
      'Content-Type': 'application/json',
      'Prefer': 'return=minimal',
    },
    body: body,
  );

  if (resp.statusCode >= 200 && resp.statusCode < 300) {
    stdout.writeln('[sync_super_admins] Sync completed successfully.');
    return;
  }

  stderr.writeln(
      '[sync_super_admins] Sync failed (${resp.statusCode}): ${resp.body}');
  exit(1);
}

Uri _buildRpcUrl(String baseUrl, String fn) {
  final trimmed = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  return Uri.parse('$trimmed/rest/v1/rpc/$fn');
}
