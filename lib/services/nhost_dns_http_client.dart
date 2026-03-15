import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

final class NhostDnsHttpClient {
  NhostDnsHttpClient._();

  static final Map<String, _DnsCacheEntry> _cache = <String, _DnsCacheEntry>{};
  static const Duration _kResolverTimeout = Duration(seconds: 4);

  static http.Client createClient({
    Duration connectionTimeout = const Duration(seconds: 60),
    Duration idleTimeout = const Duration(seconds: 60),
    int maxConnectionsPerHost = 8,
  }) {
    return IOClient(
      createHttpClient(
        connectionTimeout: connectionTimeout,
        idleTimeout: idleTimeout,
        maxConnectionsPerHost: maxConnectionsPerHost,
      ),
    );
  }

  static HttpClient createHttpClient({
    Duration connectionTimeout = const Duration(seconds: 60),
    Duration idleTimeout = const Duration(seconds: 60),
    int maxConnectionsPerHost = 8,
  }) {
    final client = HttpClient()
      ..connectionTimeout = connectionTimeout
      ..idleTimeout = idleTimeout
      ..maxConnectionsPerHost = maxConnectionsPerHost;

    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final socketFuture = _openSocket(
        uri,
        proxyHost: proxyHost,
        proxyPort: proxyPort,
        timeout: connectionTimeout,
      );
      return Future.value(ConnectionTask.fromSocket(socketFuture, () {}));
    };

    return client;
  }

  static Future<Socket> _openSocket(
    Uri uri, {
    String? proxyHost,
    int? proxyPort,
    required Duration timeout,
  }) async {
    final host = proxyHost ?? uri.host;
    final port = proxyPort ??
        (uri.hasPort ? uri.port : (uri.scheme.toLowerCase() == 'http' ? 80 : 443));
    final useTls = proxyHost == null && uri.scheme.toLowerCase() == 'https';

    try {
      return useTls
          ? await SecureSocket.connect(host, port, timeout: timeout)
          : await Socket.connect(host, port, timeout: timeout);
    } on SocketException catch (e) {
      if (!_shouldUseDnsFallback(host) || !_isFailedHostLookup(e)) {
        rethrow;
      }

      stdout.writeln(
        '[NHOST_DNS] system lookup failed for $host, trying DoH fallback',
      );
      final resolved = await _resolveHostViaDoh(host);
      if (resolved == null) {
        stdout.writeln('[NHOST_DNS] DoH fallback failed for $host');
        rethrow;
      }

      stdout.writeln('[NHOST_DNS] resolved $host -> ${resolved.address}');

      if (!useTls) {
        return Socket.connect(resolved.address, port, timeout: timeout);
      }

      final raw = await Socket.connect(resolved.address, port, timeout: timeout);
      try {
        return await SecureSocket.secure(raw, host: host);
      } catch (_) {
        raw.destroy();
        rethrow;
      }
    }
  }

  static bool _shouldUseDnsFallback(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized.endsWith('.nhost.run');
  }

  static bool _isFailedHostLookup(SocketException error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('failed host lookup') ||
        msg.contains('no such host is known') ||
        msg.contains('errno = 11001');
  }

  static Future<InternetAddress?> _resolveHostViaDoh(String host) async {
    final now = DateTime.now();
    final cached = _cache[host];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      stdout.writeln(
        '[NHOST_DNS] cache hit for $host -> ${cached.address.address}',
      );
      return cached.address;
    }

    final resolved = await _queryGoogleDns(host) ?? await _queryCloudflareDns(host);
    if (resolved == null) return null;
    _cache[host] = resolved;
    return resolved.address;
  }

  static Future<_DnsCacheEntry?> _queryGoogleDns(String host) async {
    return _queryJsonResolver(
      resolverHost: 'dns.google',
      resolverIp: '8.8.8.8',
      path: '/resolve?name=${Uri.encodeQueryComponent(host)}&type=A',
      accept: 'application/json',
    );
  }

  static Future<_DnsCacheEntry?> _queryCloudflareDns(String host) async {
    return _queryJsonResolver(
      resolverHost: 'cloudflare-dns.com',
      resolverIp: '1.1.1.1',
      path: '/dns-query?name=${Uri.encodeQueryComponent(host)}&type=A',
      accept: 'application/dns-json',
    );
  }

  static Future<_DnsCacheEntry?> _queryJsonResolver(
    {
    required String resolverHost,
    required String resolverIp,
    required String path,
    required String accept,
  }) async {
    Socket? raw;
    SecureSocket? socket;
    try {
      raw = await Socket.connect(
        resolverIp,
        443,
        timeout: _kResolverTimeout,
      );
      socket = await SecureSocket.secure(
        raw,
        host: resolverHost,
        supportedProtocols: const <String>['http/1.1'],
      ).timeout(_kResolverTimeout);

      final request = StringBuffer()
        ..write('GET $path HTTP/1.1\r\n')
        ..write('Host: $resolverHost\r\n')
        ..write('Accept: $accept\r\n')
        ..write('Accept-Encoding: identity\r\n')
        ..write('Connection: close\r\n')
        ..write('\r\n');
      socket.write(request.toString());
      await socket.flush();

      final responseBytes = await socket
          .fold<BytesBuilder>(BytesBuilder(), (builder, data) {
            builder.add(data);
            return builder;
          })
          .timeout(_kResolverTimeout);
      final rawResponse = responseBytes.takeBytes();
      final splitAt = _indexOfHeaderTerminator(rawResponse);
      if (splitAt < 0) return null;
      final headerText = latin1.decode(rawResponse.sublist(0, splitAt));
      final statusLine = headerText.split('\r\n').first;
      final parts = statusLine.split(' ');
      final statusCode = parts.length >= 2 ? int.tryParse(parts[1]) : null;
      if (statusCode == null || statusCode < 200 || statusCode >= 300) {
        return null;
      }
      final bodyBytes = _extractHttpBody(
        headersText: headerText,
        rawResponse: rawResponse,
        bodyOffset: splitAt + 4,
      );
      if (bodyBytes == null) return null;
      final body = utf8.decode(bodyBytes, allowMalformed: true);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final answers = decoded['Answer'];
      if (answers is! List) return null;
      for (final answer in answers) {
        if (answer is! Map) continue;
        final type = answer['type'];
        final data = answer['data']?.toString().trim() ?? '';
        if ((type == 1 || type == 28) && data.isNotEmpty) {
          final address = InternetAddress.tryParse(data);
          if (address == null) continue;
          final ttl = int.tryParse(answer['TTL']?.toString() ?? '') ?? 300;
          final boundedTtl = ttl < 60 ? 60 : (ttl > 3600 ? 3600 : ttl);
          return _DnsCacheEntry(
            address,
            DateTime.now().add(Duration(seconds: boundedTtl)),
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
      try {
        raw?.destroy();
      } catch (_) {}
    }
  }

  static int _indexOfHeaderTerminator(Uint8List bytes) {
    for (var i = 0; i <= bytes.length - 4; i += 1) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static Uint8List? _extractHttpBody({
    required String headersText,
    required Uint8List rawResponse,
    required int bodyOffset,
  }) {
    final headers = <String, String>{};
    final lines = headersText.split('\r\n');
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final name = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim();
      headers[name] = value;
    }

    final transferEncoding =
        (headers['transfer-encoding'] ?? '').toLowerCase();
    final contentEncoding =
        (headers['content-encoding'] ?? '').toLowerCase();
    if (contentEncoding.isNotEmpty && contentEncoding != 'identity') {
      return null;
    }

    final body = Uint8List.sublistView(rawResponse, bodyOffset);
    if (transferEncoding.contains('chunked')) {
      return _decodeChunkedBody(body);
    }

    final contentLength = int.tryParse(headers['content-length'] ?? '');
    if (contentLength == null) {
      return body;
    }
    if (contentLength < 0 || contentLength > body.length) {
      return null;
    }
    return Uint8List.fromList(body.sublist(0, contentLength));
  }

  static Uint8List? _decodeChunkedBody(Uint8List body) {
    final output = BytesBuilder(copy: false);
    var offset = 0;

    while (offset < body.length) {
      final lineEnd = _indexOfCrLf(body, offset);
      if (lineEnd < 0) return null;

      final sizeLine = ascii
          .decode(body.sublist(offset, lineEnd), allowInvalid: true)
          .trim();
      final semicolon = sizeLine.indexOf(';');
      final sizeHex = (semicolon >= 0 ? sizeLine.substring(0, semicolon) : sizeLine)
          .trim();
      final chunkSize = int.tryParse(sizeHex, radix: 16);
      if (chunkSize == null) return null;

      offset = lineEnd + 2;
      if (chunkSize == 0) {
        return output.takeBytes();
      }

      final chunkEnd = offset + chunkSize;
      if (chunkEnd > body.length) return null;
      output.add(body.sublist(offset, chunkEnd));
      offset = chunkEnd;

      if (offset + 2 > body.length ||
          body[offset] != 13 ||
          body[offset + 1] != 10) {
        return null;
      }
      offset += 2;
    }

    return null;
  }

  static int _indexOfCrLf(Uint8List bytes, int start) {
    for (var i = start; i <= bytes.length - 2; i += 1) {
      if (bytes[i] == 13 && bytes[i + 1] == 10) {
        return i;
      }
    }
    return -1;
  }
}

final class _DnsCacheEntry {
  const _DnsCacheEntry(this.address, this.expiresAt);

  final InternetAddress address;
  final DateTime expiresAt;
}
