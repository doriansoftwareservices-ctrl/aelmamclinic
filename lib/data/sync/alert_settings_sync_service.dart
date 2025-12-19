import 'package:aelmamclinic/domain/alerts/models/alert_settings.dart';

/// Provides conversion helpers for syncing `alert_settings` rows with Nhost.
class AlertSettingsSyncService {
  const AlertSettingsSyncService._();

  /// Prepares a local row before pushing it to the cloud backend.
  static Map<String, dynamic> toCloudMap(Map<String, dynamic> localRow) =>
      AlertSettingsMapper.toCloudMap(localRow);

  /// Normalises a remote row before saving it locally.
  static Map<String, dynamic> fromCloudMap(
    Map<String, dynamic> remoteRow,
    Set<String> allowedLocalColumns,
  ) =>
      AlertSettingsMapper.fromCloudMap(remoteRow, allowedLocalColumns);
}
