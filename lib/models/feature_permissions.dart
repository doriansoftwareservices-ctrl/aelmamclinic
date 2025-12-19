class FeaturePermissions {
  final Set<String> allowedFeatures;
  final bool canCreate;
  final bool canUpdate;
  final bool canDelete;

  const FeaturePermissions({
    required this.allowedFeatures,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
  });

  FeaturePermissions copyWith({
    Set<String>? allowedFeatures,
    bool? canCreate,
    bool? canUpdate,
    bool? canDelete,
  }) {
    return FeaturePermissions(
      allowedFeatures: allowedFeatures ?? this.allowedFeatures,
      canCreate: canCreate ?? this.canCreate,
      canUpdate: canUpdate ?? this.canUpdate,
      canDelete: canDelete ?? this.canDelete,
    );
  }

  static FeaturePermissions defaultsAllAllowed() => const FeaturePermissions(
        allowedFeatures: <String>{},
        canCreate: true,
        canUpdate: true,
        canDelete: true,
      );

  factory FeaturePermissions.fromRpcPayload(dynamic payload) {
    Map<String, dynamic>? row;
    if (payload is Map) {
      row = Map<String, dynamic>.from(payload);
    } else if (payload is List && payload.isNotEmpty) {
      row = Map<String, dynamic>.from(payload.first as Map);
    }
    if (row == null) return FeaturePermissions.defaultsAllAllowed();

    final list =
        (row['allowed_features'] as List?)?.map((e) => '$e').toList() ??
            const <String>[];
    return FeaturePermissions(
      allowedFeatures: Set<String>.from(list),
      canCreate: (row['can_create'] as bool?) ?? true,
      canUpdate: (row['can_update'] as bool?) ?? true,
      canDelete: (row['can_delete'] as bool?) ?? true,
    );
  }
}

class FeaturePermissionsFetchException implements Exception {
  final String message;
  final FeaturePermissions? fallback;
  final Object? cause;
  final StackTrace? stackTrace;

  const FeaturePermissionsFetchException({
    required this.message,
    this.fallback,
    this.cause,
    this.stackTrace,
  });

  @override
  String toString() => message;
}
