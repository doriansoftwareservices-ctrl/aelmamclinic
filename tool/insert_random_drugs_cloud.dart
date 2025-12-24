// tool/insert_random_drugs_cloud.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:http/http.dart' as http;

String _reqEnv(String key) {
  final v = Platform.environment[key];
  if (v == null || v.isEmpty) {
    stderr.writeln('Missing env var: $key');
    exit(2);
  }
  return v;
}

Future<void> main(List<String> args) async {
  // بيئة Nhost
  final url = Platform.environment['NHOST_GRAPHQL_URL'] ??
      Platform.environment['HASURA_GRAPHQL_URL'] ??
      NhostConfig.graphqlUrl;
  final adminSecret = Platform.environment['HASURA_GRAPHQL_ADMIN_SECRET'] ??
      Platform.environment['NHOST_ADMIN_SECRET'];
  if (url.trim().isEmpty) {
    stderr.writeln('Missing env var: NHOST_GRAPHQL_URL');
    exit(2);
  }
  if (adminSecret == null || adminSecret.trim().isEmpty) {
    stderr.writeln('Missing env var: HASURA_GRAPHQL_ADMIN_SECRET');
    exit(2);
  }
  final adminSecretValue = adminSecret.trim();

  // هوية المزامنة
  final accountId = _reqEnv('ACCOUNT_ID');
  final deviceId = Platform.environment['DEVICE_ID'] ?? 'cli-one';

  // عدد الإدخالات (اختياري: أول وسيطة)، الافتراضي 10
  final count = args.isNotEmpty ? int.tryParse(args.first) ?? 10 : 10;

  final now = DateTime.now().toUtc();
  final iso = now.toIso8601String();

  // base لضمان local_id فريد عبر التشغيلات (< 1e9)
  final base = now.millisecondsSinceEpoch % 800000000; // < 8e8
  final rand = Random.secure();
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

  final rows = <Map<String, dynamic>>[];
  for (var i = 0; i < count; i++) {
    final localId = base + i; // يبقى < 1e9
    final suffix =
        List.generate(5, (_) => alphabet[rand.nextInt(alphabet.length)]).join();
    final name = 'CLI-SmokeDrug-${now.millisecondsSinceEpoch}-$i-$suffix';

    rows.add({
      // أعمدة التزامن المطلوبة سحابيًا
      'account_id': accountId,
      'device_id': deviceId,
      'local_id': localId,
      'updated_at': iso,

      // بيانات جدول drugs (حسب allow-list لديك)
      'name': name,
      'notes': 'Inserted by CLI at $iso',
      'created_at': iso,
    });
  }

  stdout.writeln(
    '→ Upserting $count drugs to Nhost as account=$accountId device=$deviceId ...',
  );

  try {
    final constraint = Platform.environment['DRUGS_CONSTRAINT'] ??
        'drugs_account_id_device_id_local_id_key';
    final payload = {
      'query': r'''
        mutation InsertDrugs($objects: [drugs_insert_input!]!, $constraint: drugs_constraint!) {
          insert_drugs(
            objects: $objects,
            on_conflict: {
              constraint: $constraint,
              update_columns: [name, notes, updated_at]
            }
          ) {
            affected_rows
            returning {
              name
              local_id
            }
          }
        }
      ''',
      'variables': {
        'objects': rows,
        'constraint': constraint,
      },
    };

    final resp = await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'x-hasura-admin-secret': adminSecretValue,
      },
      body: jsonEncode(payload),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      stderr.writeln('❌ Error during upsert: ${resp.statusCode} ${resp.body}');
      exit(1);
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final result = (data['data']?['insert_drugs'] as Map?) ?? const {};
    final returning = (result['returning'] as List?) ?? const [];
    stdout.writeln(
      '✅ Upsert finished. Server echoed ${returning.length} rows.',
    );
    for (final r in returning.take(5).whereType<Map>()) {
      stdout.writeln(' • ${r['name']} (local_id=${r['local_id']})');
    }
    if (returning.length > 5) stdout.writeln(' • ...');
  } catch (e) {
    stderr.writeln('❌ Error during upsert: $e');
    exit(1);
  }
}
