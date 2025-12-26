// tool/insert_random_drugs.dart
import 'dart:math';

import 'package:aelmamclinic/services/db_service.dart';

Future<void> main(List<String> args) async {
  final db = await DBService.instance.database;

  final rand = Random.secure();
  String _randSuffix(int len) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(len, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  final now = DateTime.now();
  int success = 0;

  for (int i = 0; i < 10; i++) {
    final name = 'SmokeDrug-${now.millisecondsSinceEpoch}-$i-${_randSuffix(5)}';
    final row = <String, Object?>{
      'name': name,
      'notes': 'Inserted by CLI script at $now',
      'createdAt': now.toIso8601String(),
    };

    try {
      final id = await db.insert('drugs', row);
      success++;
      print('✅ Inserted #$i → id=$id, name=$name');
    } catch (e) {
      print('❌ Failed to insert #$i: $e');
    }
  }

  // إغلاق نظيف (إن وُجدت الدالة في DBService)
  try {
    await DBService.instance.flushAndClose();
  } catch (_) {}

  print('\n🎯 Done. Inserted $success/10 drugs locally.');
  print('➡️  الآن شغّل:  dart run tool/sync_cross_device_smoke_test.dart');
}
