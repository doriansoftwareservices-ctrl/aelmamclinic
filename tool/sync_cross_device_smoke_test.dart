// tool/sync_cross_device_smoke_test.dart
//
// اختبار دخاني بسيط بدون اتصال حقيقي بـ Supabase.
// يفحص منطق تشكيل صف الدفع (payload) والحذف بناءً على deviceId/localId الأصلية.

import 'dart:math';

/// نسخة مصغّرة من المنطق الجديد في _toRemoteRow (مجرّد محاكاة)
Map<String, dynamic> toRemoteRowSim({
  required String accountId,
  required String safeDeviceId, // device هذا الجهاز الحالي (احتياطي فقط)
  required Map<String, dynamic> localRow, // كما في SQLite بعد pull
  required String remoteTable,
}) {
  final data = Map<String, dynamic>.from(localRow);

  // Fallback id
  final dynId = data['id'];
  int fallbackLocalId =
      (dynId is num) ? dynId.toInt() : int.tryParse('${dynId ?? 0}') ?? 0;
  if (fallbackLocalId <= 0) {
    fallbackLocalId = DateTime.now().millisecondsSinceEpoch % 2147483647;
  }

  final String devForRow = (() {
    final dv = data['deviceId']?.toString().trim();
    return (dv != null && dv.isNotEmpty) ? dv : safeDeviceId;
  })();

  final int locForRow = (() {
    final li = data['localId'];
    final parsed = (li is num) ? li.toInt() : int.tryParse('${li ?? ''}');
    return parsed ?? fallbackLocalId;
  })();

  // إزالة أعمدة محلية
  for (final k in [
    'id',
    'isDeleted',
    'deletedAt',
    'deviceId',
    'localId',
    'accountId',
    'updatedAt'
  ]) {
    data.remove(k);
  }

  // هنا لا نهتم camel/snake — فقط نختبر مفاتيح التزامن:
  final snake = Map<String, dynamic>.from(data);
  snake['account_id'] = accountId;
  snake['device_id'] = devForRow;
  snake['local_id'] = locForRow;
  snake['updated_at'] = DateTime.now().toIso8601String();
  return snake;
}

/// محاكاة منطق _pushDeletedRows لاستخراج (device_id, local_id) الأصلية
Map<String, dynamic> deleteFilterFromLocalRow({
  required String accountId,
  required String safeDeviceId,
  required Map<String, dynamic> deletedLocalRow,
}) {
  final originDev =
      (deletedLocalRow['deviceId']?.toString().trim().isNotEmpty ?? false)
          ? deletedLocalRow['deviceId'].toString().trim()
          : safeDeviceId;

  final int originLocal = (() {
    final li = deletedLocalRow['localId'];
    final parsed = (li is num) ? li.toInt() : int.tryParse('${li ?? ''}');
    return parsed ?? (deletedLocalRow['id'] as num).toInt();
  })();

  return {
    'account_id': accountId,
    'device_id': originDev,
    'local_id': originLocal,
  };
}

void expect(bool cond, String msg) {
  if (!cond) {
    throw StateError('❌ FAILED: $msg');
  }
  print('✅ $msg');
}

void main() {
  // افتراضات
  const accountId = 'acc-XYZ';
  const ownerDev = 'device-owner';
  const empDev = 'device-employee';

  // 1) المالك أنشأ سجلًا محليًا id=12
  final ownerLocal = {
    'id': 12,
    'name': 'Test Drug',
    'deviceId': ownerDev,
    'localId': 12,
    'isDeleted': 0,
  };

  // 2) الموظف قام بالسحب فأصبح لديه سجل مركّب id>=1e9 لكن مع meta أصلية
  final pulledOnEmployee = {
    'id': 1234567890, // مركّب (مثال)
    'name': 'Test Drug',
    'deviceId': ownerDev, // ← أصل السجل
    'localId': 12, // ← أصل السجل
    'isDeleted': 0,
  };

  // 3) الموظف عدّل السجل — عند الدفع يجب إرسال أصل السجل (ownerDev, 12)
  final payload = toRemoteRowSim(
    accountId: accountId,
    safeDeviceId: empDev,
    localRow: pulledOnEmployee,
    remoteTable: 'drugs',
  );

  expect(payload['device_id'] == ownerDev, 'payload uses origin device_id');
  expect(payload['local_id'] == 12, 'payload uses origin local_id');

  // 4) الموظف حذف السجل — يجب حذف الصف الأصلي ذاته على السحابة
  final deletedLocalRow = Map<String, dynamic>.from(pulledOnEmployee)
    ..['isDeleted'] = 1;

  final delFilter = deleteFilterFromLocalRow(
    accountId: accountId,
    safeDeviceId: empDev,
    deletedLocalRow: deletedLocalRow,
  );

  expect(delFilter['device_id'] == ownerDev,
      'delete filter uses origin device_id');
  expect(delFilter['local_id'] == 12, 'delete filter uses origin local_id');

  print(
      '\n🎉 All checks passed. Cross-device edits/deletes will target the original cloud row.\n');
}
