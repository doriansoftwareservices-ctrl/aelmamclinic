/// Domain-level helpers for the `alert_settings` table.
///
/// This file keeps the authoritative list of column keys and the
/// transformations required when syncing data with Supabase. The sync
/// service and any domain mappers should use these helpers to guarantee
/// that we always talk about the same keys (especially `item_uuid`).
class AlertSettingsFields {
  AlertSettingsFields._();

  static const String table = 'alert_settings';

  static const String id = 'id';
  static const String accountId = 'account_id';
  static const String localId = 'local_id';
  static const String deviceId = 'device_id';

  static const String itemId = 'item_id';
  static const String itemUuid = 'item_uuid';
  static const String itemUuidCamel = 'itemUuid';

  static const String threshold = 'threshold';
  static const String isEnabled = 'is_enabled';
  static const String isEnabledCamel = 'isEnabled';
  static const String notifyTime = 'notify_time';
  static const String notifyTimeCamel = 'notifyTime';
  static const String lastTriggered = 'last_triggered';
  static const String lastTriggeredCamel = 'lastTriggered';
  static const String createdAt = 'created_at';
  static const String createdAtCamel = 'createdAt';
  static const String updatedAt = 'updated_at';
  static const String updatedAtCamel = 'updatedAt';
}

/// Converts alert settings payloads to/from the structure expected by Supabase.
class AlertSettingsMapper {
  const AlertSettingsMapper._();

  /// Normalises local rows before sending them to Supabase.
  static Map<String, dynamic> toCloudMap(Map<String, dynamic> localRow) {
    final out = <String, dynamic>{}..addAll(localRow);

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value.toUtc();
      final text = value.toString().trim();
      if (text.isEmpty) return null;
      return DateTime.tryParse(text)?.toUtc();
    }

    final notify = parseDate(out[AlertSettingsFields.notifyTime] ??
        out[AlertSettingsFields.notifyTimeCamel]);
    if (notify != null) {
      out[AlertSettingsFields.notifyTime] = notify.toIso8601String();
    } else if (out.containsKey(AlertSettingsFields.notifyTime) &&
        out[AlertSettingsFields.notifyTime] is! String) {
      out[AlertSettingsFields.notifyTime] = null;
    }
    out.remove(AlertSettingsFields.notifyTimeCamel);

    final last = parseDate(out[AlertSettingsFields.lastTriggered] ??
        out[AlertSettingsFields.lastTriggeredCamel]);
    if (last != null) {
      out[AlertSettingsFields.lastTriggered] = last.toIso8601String();
    }
    out.remove(AlertSettingsFields.lastTriggeredCamel);

    final dynamic rawUuid = out.containsKey(AlertSettingsFields.itemUuid)
        ? out[AlertSettingsFields.itemUuid]
        : out[AlertSettingsFields.itemUuidCamel];
    if (rawUuid is String) {
      final trimmed = rawUuid.trim();
      out[AlertSettingsFields.itemUuid] = trimmed.isEmpty ? null : trimmed;
    } else if (rawUuid == null &&
        out.containsKey(AlertSettingsFields.itemUuid)) {
      out[AlertSettingsFields.itemUuid] = null;
    }
    out.remove(AlertSettingsFields.itemUuidCamel);

    return out;
  }

  /// Normalises Supabase rows before saving them locally.
  static Map<String, dynamic> fromCloudMap(
    Map<String, dynamic> remoteRow,
    Set<String> allowedLocalColumns,
  ) {
    final out = <String, dynamic>{}..addAll(remoteRow);

    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value.toUtc();
      final text = value.toString().trim();
      if (text.isEmpty) return null;
      return DateTime.tryParse(text)?.toUtc();
    }

    void normaliseDate(String snakeKey) {
      if (!out.containsKey(snakeKey)) return;
      final parsed = parseDate(out[snakeKey]);
      if (parsed != null) {
        out[snakeKey] = parsed.toIso8601String();
      }
    }

    normaliseDate(AlertSettingsFields.notifyTime);
    normaliseDate(AlertSettingsFields.lastTriggered);

    bool looksLikeUuid(String value) {
      const uuidPattern = r'^[0-9a-fA-F-]{32,36}$';
      if (!RegExp(uuidPattern).hasMatch(value)) return false;
      return value.contains('-');
    }

    String? normaliseUuid(dynamic value) {
      if (value == null) return null;
      final text = value.toString().trim();
      if (text.isEmpty) return null;
      return looksLikeUuid(text) ? text : null;
    }

    final normalisedUuid = normaliseUuid(
      out[AlertSettingsFields.itemUuid] ??
          out[AlertSettingsFields.itemUuidCamel] ??
          out[AlertSettingsFields.itemId],
    );
    if (normalisedUuid != null) {
      out[AlertSettingsFields.itemUuid] = normalisedUuid;
      if (allowedLocalColumns.contains(AlertSettingsFields.itemUuidCamel)) {
        out[AlertSettingsFields.itemUuidCamel] = normalisedUuid;
      }
    }

    return out;
  }
}
