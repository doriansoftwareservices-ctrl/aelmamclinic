import 'dart:io';

import 'package:aelmamclinic/core/nhost_config.dart';

Future<bool> probeHasRealInternet() async {
  final targets = _backendTargets();
  for (final uri in targets) {
    if (await _probeBackend(uri)) {
      return true;
    }
  }
  return false;
}

List<Uri> _backendTargets() {
  final targets = <Uri>[];
  for (final raw in <String>[
    NhostConfig.authUrl,
    NhostConfig.graphqlUrl,
    NhostConfig.functionsUrl,
  ]) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      continue;
    }
    if (targets.any((existing) => existing.toString() == uri.toString())) {
      continue;
    }
    targets.add(uri);
  }
  return targets;
}

Future<bool> _probeBackend(Uri uri) async {
  if (await _socketProbe(uri)) return true;
  return _httpProbe(uri);
}

Future<bool> _httpProbe(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  try {
    if (await _request(client, uri, method: 'HEAD')) return true;
    return _request(client, uri, method: 'GET');
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _request(
  HttpClient client,
  Uri uri, {
  required String method,
}) async {
  final req = await client.openUrl(method, uri);
  req.followRedirects = false;
  req.headers.set(HttpHeaders.acceptHeader, 'application/json');
  final res = await req.close().timeout(const Duration(seconds: 3));
  return res.statusCode >= 200 && res.statusCode < 500;
}

Future<bool> _socketProbe(Uri uri) async {
  Socket? socket;
  try {
    final port = uri.hasPort
        ? uri.port
        : (uri.scheme.toLowerCase() == 'http' ? 80 : 443);
    socket = await Socket.connect(
      uri.host,
      port,
      timeout: const Duration(seconds: 2),
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      socket?.destroy();
    } catch (_) {}
  }
}
