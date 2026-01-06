import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:nhost_storage_dart/nhost_storage_dart.dart';

import '../core/constants.dart';
import '../core/nhost_config.dart';
import '../core/nhost_manager.dart';
import 'nhost_api_client.dart';

/// Minimal storage wrapper for Nhost (REST).
///
/// Notes:
/// - Nhost storage uses file IDs; upload returns metadata containing `id`.
/// - This service keeps the API surface small and is used by chat attachments.
class NhostStorageService {
  NhostStorageService({NhostApiClient? api}) : _api = api ?? NhostApiClient();

  final NhostApiClient _api;

  /// Returns a direct download URL for a file by its id.
  String publicFileUrl(String fileId) {
    final base = NhostConfig.storageUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/files/$fileId';
  }

  /// Downloads a file as raw bytes using the current auth session.
  Future<List<int>> downloadFile(String fileId) async {
    final response = await _api.getStorage('files/$fileId');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Download failed: ${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  /// Uploads a file to Nhost storage.
  /// Returns the JSON response (contains file metadata including `id`).
  Future<Map<String, dynamic>> uploadFile({
    required File file,
    String? name,
    String? bucketId,
    String? mimeType,
  }) async {
    final bucket = bucketId?.trim();
    final filename = (name == null || name.trim().isEmpty)
        ? file.uri.pathSegments.last
        : name.trim();
    try {
      final bytes = await file.readAsBytes();
      final fileData = FileData(
        Uint8List.fromList(bytes),
        filename: filename,
        contentType: mimeType,
      );
      final metadata = UploadFileMetadata(name: filename);
      final results = await NhostManager.client.storage.uploadFiles(
        files: [fileData],
        bucketId: (bucket != null && bucket.isNotEmpty) ? bucket : null,
        metadataList: [metadata],
      );
      if (results.isEmpty) {
        return <String, dynamic>{};
      }
      final uploaded = results.first;
      return <String, dynamic>{
        'id': uploaded.id,
        'name': uploaded.name,
        'bucketId': uploaded.bucketId,
        'mimeType': uploaded.mimeType,
        'size': uploaded.size,
        'etag': uploaded.etag,
        'createdAt': uploaded.createdAt.toIso8601String(),
      };
    } catch (e) {
      throw HttpException('Upload failed: $e');
    }
  }

  /// Deletes a file by id.
  Future<void> deleteFile(String fileId) async {
    final response = await _api.deleteStorage('files/$fileId');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Delete failed: ${response.statusCode}',
      );
    }
  }

  /// Creates a signed URL for a file id using the storage API.
  /// Returns null if signing fails.
  Future<String?> createSignedUrl(
    String fileId, {
    int? expiresInSeconds,
  }) async {
    final ttl = expiresInSeconds ?? AppConstants.storageSignedUrlTTLSeconds;
    try {
      final url = _api.storageUri('files/$fileId/presigned');
      final res = await _api.postJson(url, {'expiresIn': ttl});
      final signed = res['url'] ??
          res['signedUrl'] ??
          res['presignedUrl'] ??
          res['presigned_url'];
      final value = signed?.toString() ?? '';
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  void dispose() => _api.dispose();
}
