import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/nhost_config.dart';
import '../core/nhost_manager.dart';

/// Thin HTTP helper that injects Nhost auth headers for REST endpoints.
class NhostApiClient {
  NhostApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Map<String, String>> _authHeaders({
    Map<String, String>? extra,
  }) async {
    final headers = <String, String>{};
    final token = NhostManager.client.auth.accessToken;
    if (token != null && token.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
    }
    if (extra != null) {
      headers.addAll(extra);
    }
    return headers;
  }

  Future<Map<String, String>> authHeaders({
    Map<String, String>? extra,
  }) async {
    return _authHeaders(extra: extra);
  }

  Uri storageUri(String path) {
    final base = NhostConfig.storageUrl.replaceAll(RegExp(r'/+$'), '');
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse('$base/$cleanPath');
  }

  Future<http.Response> getStorage(
    String path, {
    Map<String, String>? headers,
  }) async {
    return _client.get(
      storageUri(path),
      headers: await _authHeaders(extra: headers),
    );
  }

  Future<http.Response> deleteStorage(
    String path, {
    Map<String, String>? headers,
  }) async {
    return _client.delete(
      storageUri(path),
      headers: await _authHeaders(extra: headers),
    );
  }

  Future<Map<String, dynamic>> postJson(
    Uri url,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
  }) async {
    final merged = await _authHeaders(
      extra: <String, String>{
        HttpHeaders.contentTypeHeader: 'application/json',
        if (headers != null) ...headers,
      },
    );
    final response = await _client.post(
      url,
      headers: merged,
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final buffer = StringBuffer()
        ..write('POST ${url.toString()} failed: ${response.statusCode}');
      if (response.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            final err = decoded['error'] ?? decoded['message'];
            if (err != null && err.toString().trim().isNotEmpty) {
              buffer.write(' - ${err.toString()}');
            } else {
              buffer.write(' - ${response.body}');
            }
          } else {
            buffer.write(' - ${response.body}');
          }
        } catch (_) {
          buffer.write(' - ${response.body}');
        }
      }
      throw HttpException(buffer.toString());
    }
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'data': decoded};
  }

  void dispose() {
    _client.close();
  }
}
