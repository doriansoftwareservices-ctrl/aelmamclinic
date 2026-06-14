import 'dart:io';

import 'package:aelmamclinic/core/nhost_config.dart';
import 'package:aelmamclinic/core/sync/clinic_sync_models.dart';
import 'package:aelmamclinic/services/nhost_api_client.dart';

class ClinicSyncFunctionResult {
  const ClinicSyncFunctionResult({
    required this.operation,
    required this.serverTimestamp,
    this.remoteId,
    this.syncEventId,
    this.serverVersion,
    this.raw = const <String, Object?>{},
  });

  final String operation;
  final String serverTimestamp;
  final String? remoteId;
  final String? syncEventId;
  final Object? serverVersion;
  final Map<String, Object?> raw;
}

class ClinicSyncFunctionException implements Exception {
  const ClinicSyncFunctionException({
    required this.message,
    this.errorCode,
    this.statusCode,
  });

  final String message;
  final String? errorCode;
  final int? statusCode;

  bool get isConflict =>
      statusCode == 409 ||
      (errorCode ?? '').toLowerCase().contains('conflict') ||
      message.toLowerCase().contains('conflict') ||
      message.toLowerCase().contains('idempotency_payload_mismatch');

  bool get isTransient {
    final text = message.toLowerCase();
    return statusCode == null ||
        statusCode == 408 ||
        statusCode == 429 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504 ||
        text.contains('network') ||
        text.contains('socket') ||
        text.contains('timeout') ||
        text.contains('deadline') ||
        text.contains('temporar') ||
        text.contains('connection');
  }

  bool get shouldFallbackToGraphql {
    final text = message.toLowerCase();
    return statusCode == 404 ||
        text.contains('404') ||
        text.contains('not found') ||
        text.contains('no such function') ||
        text.contains('function unavailable');
  }

  @override
  String toString() {
    final code = errorCode == null ? '' : '[$errorCode] ';
    return '${code}${message.trim()}';
  }
}

class ClinicSyncRemoteGateway {
  const ClinicSyncRemoteGateway();

  Uri _functionUri(String path) {
    final base = NhostConfig.functionsUrl.replaceAll(RegExp(r'/+$'), '');
    final cleanPath = path.replaceFirst(RegExp(r'^/+'), '');
    return Uri.parse('$base/$cleanPath');
  }

  Future<ClinicSyncFunctionResult> pushOutboxEntry({
    required ClinicOutboxEntry entry,
    required Map<String, Object?> remotePayload,
  }) async {
    final api = NhostApiClient();
    try {
      final body = <String, Object?>{
        'operation_type': entry.operationType,
        'entity_table': entry.entityTable,
        'entity_id': entry.entityId,
        'remote_id': entry.remoteId,
        'client_mutation_id': entry.clientMutationId,
        'account_id': entry.accountId,
        'device_id': entry.deviceId,
        'local_id': entry.localId,
        'payload': remotePayload,
        'local_reference': entry.localReference,
      };
      final response = await api.postJson(_functionUri('clinic-sync'), body);
      if (response['success'] != true) {
        throw ClinicSyncFunctionException(
          message: (response['user_message'] ?? response['message'] ?? '')
              .toString()
              .trim(),
          errorCode: response['error_code']?.toString(),
        );
      }
      final data = response['data'] is Map
          ? Map<String, Object?>.from(response['data'] as Map)
          : const <String, Object?>{};
      return ClinicSyncFunctionResult(
        operation: (response['operation'] ?? entry.operationType).toString(),
        serverTimestamp: (response['server_timestamp'] ?? '').toString(),
        remoteId: data['remote_id']?.toString(),
        syncEventId: data['sync_event_id']?.toString(),
        serverVersion: data['server_version'],
        raw: Map<String, Object?>.from(response),
      );
    } on ClinicSyncFunctionException {
      rethrow;
    } on HttpException catch (error) {
      throw ClinicSyncFunctionException(
        message: error.message,
        statusCode: _statusCodeFromMessage(error.message),
      );
    } catch (error) {
      throw ClinicSyncFunctionException(message: error.toString());
    } finally {
      api.dispose();
    }
  }

  int? _statusCodeFromMessage(String message) {
    final match = RegExp(r'failed:\s+(\d{3})').firstMatch(message);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }
}
