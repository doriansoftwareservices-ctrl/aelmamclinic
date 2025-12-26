class ProvisioningResult {
  final String? accountId;
  final String? userUid;
  final String role;
  final List<String> warnings;

  ProvisioningResult({
    required this.accountId,
    required this.userUid,
    required this.role,
    List<String>? warnings,
  }) : warnings =
            warnings == null ? const [] : List<String>.unmodifiable(warnings);

  bool get hasWarnings => warnings.isNotEmpty;
}
