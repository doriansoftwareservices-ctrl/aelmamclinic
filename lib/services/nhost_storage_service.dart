import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:nhost_storage_dart/nhost_storage_dart.dart';
import 'package:http_parser/http_parser.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../core/constants.dart';
import '../core/nhost_config.dart';
import '../core/nhost_manager.dart';
import 'nhost_api_client.dart';
import 'nhost_graphql_service.dart';

/// Minimal storage wrapper for Nhost (REST).
///
/// Notes:
/// - Nhost storage uses file IDs; upload returns metadata containing `id`.
/// - This service keeps the API surface small and is used by chat attachments.
class NhostStorageService {
  NhostStorageService({NhostApiClient? api}) : _api = api ?? NhostApiClient();

  final NhostApiClient _api;
  final GraphQLClient _gql = NhostGraphqlService.client;
  final Map<String, String> _fileIdCache = {};

  /// Returns a direct download URL for a file by its id.
  String publicFileUrl(String fileId) {
    final base = NhostConfig.storageUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/files/$fileId';
  }

  bool _looksLikeUuid(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    final re = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return re.hasMatch(v);
  }

  String? extractFileIdFromUrl(String url) {
    final v = url.trim();
    if (v.isEmpty) return null;
    final re = RegExp(
      r'/files/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
    );
    final match = re.firstMatch(v);
    if (match == null) return null;
    final id = match.group(1);
    return (id == null || id.isEmpty) ? null : id;
  }

  Future<String?> resolveSignedUrlFromUrl(String url,
      {int? expiresInSeconds}) async {
    final fileId = extractFileIdFromUrl(url);
    if (fileId == null) return null;
    final signed = await createSignedUrl(
      fileId,
      expiresInSeconds:
          expiresInSeconds ?? AppConstants.storageSignedUrlTTLSeconds,
    );
    if (signed != null && signed.isNotEmpty) return signed;
    return publicFileUrl(fileId);
  }

  /// Resolve storage file id by bucket+path using GraphQL (cached).
  Future<String?> resolveFileId({
    required String bucket,
    required String path,
  }) async {
    final trimmedBucket = bucket.trim();
    final trimmedPath = path.trim();
    if (trimmedBucket.isEmpty || trimmedPath.isEmpty) return null;
    if (_looksLikeUuid(trimmedPath)) return trimmedPath;

    final cacheKey = '$trimmedBucket|$trimmedPath';
    final cached = _fileIdCache[cacheKey];
    if (cached != null && cached.isNotEmpty) return cached;

    const query = r'''
      query StorageFileId($bucket: String!, $name: String!) {
        files(
          where: {bucketId: {_eq: $bucket}, name: {_eq: $name}},
          limit: 1
        ) {
          id
        }
      }
    ''';
    try {
      final result = await _gql.query(
        QueryOptions(
          document: gql(query),
          variables: {'bucket': trimmedBucket, 'name': trimmedPath},
          fetchPolicy: FetchPolicy.noCache,
        ),
      );
      if (result.hasException) return null;
      final rows = (result.data?['files'] as List?) ?? const [];
      if (rows.isEmpty) return null;
      final id = (rows.first as Map?)?['id']?.toString();
      if (id == null || id.isEmpty) return null;
      _fileIdCache[cacheKey] = id;
      return id;
    } catch (_) {
      return null;
    }
  }

  /// Resolve a signed URL for bucket/path, similar to subscription proof flow.
  Future<String?> resolveSignedUrlForPath({
    required String bucket,
    required String path,
    int? expiresInSeconds,
  }) async {
    final fileId = await resolveFileId(bucket: bucket, path: path);
    if (fileId == null || fileId.isEmpty) return null;
    final signed = await createSignedUrl(
      fileId,
      expiresInSeconds: expiresInSeconds ?? AppConstants.storageSignedUrlTTLSeconds,
    );
    if (signed != null && signed.isNotEmpty) return signed;
    return publicFileUrl(fileId);
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
    Map<String, dynamic>? metadata,
  }) async {
    final bucket = bucketId?.trim();
    final filename = (name == null || name.trim().isEmpty)
        ? file.uri.pathSegments.last
        : name.trim();
    try {
      // Prefer REST for storage uploads; fall back to function only on auth errors.
      // Prefer REST for chat attachments to avoid SDK auth edge cases.
      if ((bucket ?? '').isNotEmpty &&
          (bucket ?? '') == AppConstants.chatBucketName) {
        return await _uploadFileViaRest(
          file: file,
          filename: filename,
          bucketId: bucket,
          mimeType: mimeType,
          metadata: metadata,
        );
      }

      final bytes = await file.readAsBytes();
      final fileData = FileData(
        Uint8List.fromList(bytes),
        filename: filename,
        contentType: mimeType,
      );
      final meta = UploadFileMetadata(name: filename);
      final results = await NhostManager.client.storage.uploadFiles(
        files: [fileData],
        bucketId: (bucket != null && bucket.isNotEmpty) ? bucket : null,
        metadataList: [meta],
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
      if (_shouldRetryWithRest(e)) {
        try {
          return await _uploadFileViaRest(
            file: file,
            filename: filename,
            bucketId: bucket,
            mimeType: mimeType,
            metadata: metadata,
          );
        } catch (restError) {
          if (_shouldRetryWithFunction(restError) &&
              _isFunctionUploadBucket(bucket)) {
            return _uploadFileViaFunction(
              file: file,
              filename: filename,
              bucketId: bucket,
              mimeType: mimeType,
              metadata: metadata,
            );
          }
          throw HttpException('Upload failed: $restError');
        }
      }
      throw HttpException('Upload failed: $e');
    }
  }

  bool _shouldRetryWithRest(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('statuscode=401') ||
        text.contains('statuscode=403') ||
        text.contains('unauthorized') ||
        text.contains('not authorized');
  }

  bool _shouldRetryWithFunction(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('statuscode=401') ||
        text.contains('statuscode=403') ||
        text.contains(' 401') ||
        text.contains(' 403') ||
        text.contains('403 -') ||
        text.contains('unauthorized') ||
        text.contains('not authorized');
  }

  bool _isFunctionUploadBucket(String? bucketId) {
    final bucket = (bucketId ?? '').trim().toLowerCase();
    return bucket == 'subscription-proofs' || bucket == AppConstants.chatBucketName;
  }

  Future<Map<String, dynamic>> _uploadFileViaRest({
    required File file,
    required String filename,
    String? bucketId,
    String? mimeType,
    Map<String, dynamic>? metadata,
  }) async {
    final uri = _api.storageUri('files');
    final headers = await _api.authHeaders();
    final authHeader = headers[HttpHeaders.authorizationHeader];
    // Basic diagnostics to confirm auth header presence (no token logging).
    if (authHeader == null || authHeader.isEmpty) {
      // ignore: avoid_print
      print('[STORAGE] upload missing Authorization header');
    } else {
      // ignore: avoid_print
      print('[STORAGE] upload Authorization header present');
    }
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(headers);

    final bucket = bucketId?.trim();
    if (bucket != null && bucket.isNotEmpty) {
      request.fields['bucket-id'] = bucket;
    }

    final bytes = await file.readAsBytes();
    final contentType = (mimeType == null || mimeType.trim().isEmpty)
        ? null
        : MediaType.parse(mimeType);
    request.files.add(
      http.MultipartFile.fromBytes(
        'file[]',
        bytes,
        filename: filename,
        contentType: contentType,
      ),
    );

    final meta = <String, dynamic>{'name': filename};
    if (metadata != null && metadata.isNotEmpty) {
      meta['metadata'] = metadata;
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        'metadata[]',
        utf8.encode(jsonEncode(meta)),
        filename: '',
        contentType: MediaType('application', 'json'),
      ),
    );

    final response = await request.send();
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // ignore: avoid_print
      print('[STORAGE] upload failed: ${response.statusCode} $body');
      throw HttpException(
        'Upload failed: ${response.statusCode} - $body',
      );
    }

    if (body.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final files = decoded['processedFiles'];
      if (files is List && files.isNotEmpty && files.first is Map) {
        return Map<String, dynamic>.from(files.first as Map);
      }
      return decoded;
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _uploadFileViaFunction({
    required File file,
    required String filename,
    String? bucketId,
    String? mimeType,
    Map<String, dynamic>? metadata,
  }) async {
    final bucket = (bucketId == null || bucketId.trim().isEmpty)
        ? 'subscription-proofs'
        : bucketId.trim();
    final base = NhostConfig.functionsUrl.replaceAll(RegExp(r'/+$'), '');
    final url = bucket == AppConstants.chatBucketName
        ? Uri.parse('$base/admin-upload-chat-attachment')
        : Uri.parse('$base/admin-upload-subscription-proof');
    final bytes = await file.readAsBytes();
    final payload = <String, dynamic>{
      'filename': filename,
      'bucketId': bucket,
      'mimeType': mimeType,
      'base64': base64Encode(bytes),
    };
    if (metadata != null && metadata.isNotEmpty) {
      payload['metadata'] = metadata;
    }
    final res = await _api.postJson(url, payload);
    final files = res['processedFiles'];
    if (files is List && files.isNotEmpty && files.first is Map) {
      return Map<String, dynamic>.from(files.first as Map);
    }
    return res;
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
      return await _createSignedUrlViaStorage(fileId, ttl);
    } catch (e) {
      if (_shouldRetryWithFunction(e)) {
        try {
          return await _createSignedUrlViaFunction(fileId, ttl);
        } catch (_) {
          return null;
        }
      }
      return null;
    }
  }

  Future<String?> createAdminSignedUrl(
    String fileId, {
    int? expiresInSeconds,
  }) async {
    final ttl = expiresInSeconds ?? AppConstants.storageSignedUrlTTLSeconds;
    try {
      return await _createSignedUrlViaFunction(fileId, ttl);
    } catch (_) {
      try {
        return await _createSignedUrlViaStorage(fileId, ttl);
      } catch (_) {
        return null;
      }
    }
  }

  Future<String?> _createSignedUrlViaStorage(
    String fileId,
    int ttl,
  ) async {
    final url = _api.storageUri('files/$fileId/presigned');
    final res = await _api.postJson(url, {'expiresIn': ttl});
    final signed = res['url'] ??
        res['signedUrl'] ??
        res['presignedUrl'] ??
        res['presigned_url'] ??
        res['dataUrl'] ??
        res['data_url'];
    final value = signed?.toString() ?? '';
    return value.isEmpty ? null : value;
  }

  Future<String?> _createSignedUrlViaFunction(
    String fileId,
    int ttl,
  ) async {
    final base = NhostConfig.functionsUrl.replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/admin-sign-storage-file');
    final res = await _api.postJson(url, {'fileId': fileId, 'expiresIn': ttl});
    final signed = res['url'] ??
        res['signedUrl'] ??
        res['presignedUrl'] ??
        res['presigned_url'] ??
        res['dataUrl'] ??
        res['data_url'];
    final value = signed?.toString() ?? '';
    return value.isEmpty ? null : value;
  }

  void dispose() => _api.dispose();
}
