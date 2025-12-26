// lib/models/alert_setting.dart
import 'package:aelmamclinic/domain/alerts/models/alert_settings.dart'
    as alerts_domain;

import 'item.dart';

/// إعداد تنبيه قرب النفاد.
///
/// ✅ حقول SQLite بالـ snake_case.
/// ✅ fromMap يدعم camelCase و snake_case.
/// ✅ isEnabled يُخزَّن كـ 0/1 محليًا.
/// ✅ عند الإدراج لا نُمرّر id إذا كان null/<=0 (مهم لمنع ثبات local_id).
class AlertSetting {
  static const String table = 'alert_settings';

  final int? id;
  final int itemId;
  final double threshold;
  final bool isEnabled;
  final DateTime? lastTriggered;
  final DateTime? notifyTime;
  final String? itemUuid;
  final DateTime createdAt;

  AlertSetting({
    this.id,
    required this.itemId,
    required this.threshold,
    this.isEnabled = true,
    this.lastTriggered,
    this.notifyTime,
    this.itemUuid,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /*──────────── Helpers ────────────*/
  static int? _toIntN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int _toInt0(dynamic v) => _toIntN(v) ?? 0;

  static double? _toDoubleN(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static double _toDouble0(dynamic v) => _toDoubleN(v) ?? 0.0;

  static bool _toBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v?.toString().toLowerCase();
    return s == 'true' || s == 't' || s == '1' || s == 'yes';
  }

  static DateTime? _toDateN(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  static String? _toStrN(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  /*──────── SQL (SQLite) ────────*/
  /// ملاحظة: نستخدم snake_case ليتوافق مع DBService والترقيات.
  static String get createTable => '''
  CREATE TABLE IF NOT EXISTS $table (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id         INTEGER NOT NULL UNIQUE,
    threshold       REAL    NOT NULL,
    is_enabled      INTEGER NOT NULL DEFAULT 1,
    last_triggered  TEXT,
    notify_time     TEXT,
    item_uuid       TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY(item_id) REFERENCES ${Item.table}(id) ON DELETE CASCADE
  );
  ''';

  /// ⚠️ مهم: لا نضع 'id' عند الإدراج إذا كان null/<=0
  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{
      'item_id': itemId,
      'threshold': threshold,
      'is_enabled': isEnabled ? 1 : 0,
      'last_triggered': lastTriggered?.toIso8601String(),
      'notify_time': notifyTime?.toIso8601String(),
      alerts_domain.AlertSettingsFields.itemUuid: itemUuid,
      'created_at': createdAt.toIso8601String(),
    };
    if (id != null && id! > 0) {
      m['id'] = id;
    }
    return m;
  }

  /// يدعم camelCase و snake_case
  factory AlertSetting.fromMap(Map<String, dynamic> map) => AlertSetting(
        id: _toIntN(map['id']),
        itemId: _toInt0(map['item_id'] ?? map['itemId']),
        threshold: _toDouble0(map['threshold']),
        isEnabled: _toBool(map['is_enabled'] ?? map['isEnabled'] ?? 1),
        lastTriggered: _toDateN(map['last_triggered'] ?? map['lastTriggered']),
        notifyTime: _toDateN(map['notify_time'] ?? map['notifyTime']),
        itemUuid: _toStrN(map[alerts_domain.AlertSettingsFields.itemUuid] ??
            map[alerts_domain.AlertSettingsFields.itemUuidCamel]),
        createdAt:
            _toDateN(map['created_at'] ?? map['createdAt']) ?? DateTime.now(),
      );

  AlertSetting copyWith({
    int? id,
    int? itemId,
    double? threshold,
    bool? isEnabled,
    DateTime? lastTriggered,
    DateTime? notifyTime,
    String? itemUuid,
    DateTime? createdAt,
  }) =>
      AlertSetting(
        id: id ?? this.id,
        itemId: itemId ?? this.itemId,
        threshold: threshold ?? this.threshold,
        isEnabled: isEnabled ?? this.isEnabled,
        lastTriggered: lastTriggered ?? this.lastTriggered,
        notifyTime: notifyTime ?? this.notifyTime,
        itemUuid: itemUuid ?? this.itemUuid,
        createdAt: createdAt ?? this.createdAt,
      );

  @override
  String toString() =>
      'AlertSetting(id: $id, itemId: $itemId, threshold: $threshold, isEnabled: $isEnabled, notifyTime: $notifyTime, itemUuid: $itemUuid)';
}
