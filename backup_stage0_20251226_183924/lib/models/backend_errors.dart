class BackendSchemaException implements Exception {
  final String message;
  BackendSchemaException(this.message);

  @override
  String toString() => message;
}
