import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../core/constants.dart';
import '../core/nhost_config.dart';
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
    final uri = _api.storageUri('files');
    final request = http.MultipartRequest('POST', uri);
    final filename = (name == null || name.trim().isEmpty)
        ? file.uri.pathSegments.last
        : name.trim();

    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: filename,
        contentType: mimeType == null ? null : _parseContentType(mimeType),
      ),
    );

    if (bucketId != null && bucketId.trim().isNotEmpty) {
      request.fields['bucketId'] = bucketId.trim();
    }

    request.headers.addAll(
      await _api.authHeaders(),
    );

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail =
          response.body.isEmpty ? '' : ' - ${response.body.toString()}';
      throw HttpException(
        'Upload failed: ${response.statusCode}$detail',
      );
    }
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    return _decodeJson(response.body);
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

MediaType? _parseContentType(String value) {
  try {
    final parts = value.split('/');
    if (parts.length != 2) return null;
    return MediaType(parts[0], parts[1]);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _decodeJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'data': decoded};
  } catch (_) {
    return <String, dynamic>{};
  }
}
