Future<
    ({
      List<String>? superAdminEmails,
      String? nhostSubdomain,
      String? nhostRegion,
      String? nhostGraphqlUrl,
      String? nhostAuthUrl,
      String? nhostStorageUrl,
      String? nhostFunctionsUrl,
      String? resetPasswordRedirectUrl,
      String? source
    })?> loadNhostRuntimeOverrides({
  required String windowsDataDir,
  required String legacyWindowsDataDir,
  required String linuxDataDir,
  required String macOsDataDir,
  required String androidDataDir,
  required String iosLogicalDataDir,
}) async {
  return null;
}
