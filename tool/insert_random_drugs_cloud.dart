// tool/insert_random_drugs_cloud.dart
import 'dart:io';
import 'dart:math';
import 'package:supabase/supabase.dart';

String _reqEnv(String key) {
  final v = Platform.environment[key];
  if (v == null || v.isEmpty) {
    stderr.writeln('Missing env var: $key');
    exit(2);
  }
  return v;
}

Future<void> main(List<String> args) async {
  // بيئة Supabase
  final url = _reqEnv('SUPABASE_URL');
  final anonKey = _reqEnv('SUPABASE_ANON_KEY');

  // هوية المزامنة
  final accountId = _reqEnv('ACCOUNT_ID');
  final deviceId = Platform.environment['DEVICE_ID'] ?? 'cli-one';

  // عدد الإدخالات (اختياري: أول وسيطة)، الافتراضي 10
  final count = args.isNotEmpty ? int.tryParse(args.first) ?? 10 : 10;

  final client = SupabaseClient(url, anonKey);
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
      '→ Upserting $count drugs to Supabase as account=$accountId device=$deviceId ...');

  try {
    final resp = await client
        .from('drugs')
        .upsert(
          rows,
          onConflict: 'account_id,device_id,local_id',
          ignoreDuplicates: false,
        )
        .select();

    stdout.writeln('✅ Upsert finished. Server echoed ${resp.length} rows.');
    for (final r in resp.take(5)) {
      stdout.writeln(' • ${r['name']} (local_id=${r['local_id']})');
    }
    if (resp.length > 5) stdout.writeln(' • ...');
  } catch (e) {
    stderr.writeln('❌ Error during upsert: $e');
    exit(1);
  }
}
