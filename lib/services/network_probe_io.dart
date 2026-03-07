import 'dart:io';

Future<bool> probeHasRealInternet() async {
  final probes = <String>[
    'https://clients3.google.com/generate_204',
    'https://www.cloudflare.com/cdn-cgi/trace',
  ];
  for (final url in probes) {
    if (await _httpProbe(url)) return true;
  }
  if (await _socketProbe('1.1.1.1', 443)) return true;
  if (await _socketProbe('8.8.8.8', 443)) return true;
  return false;
}

Future<bool> _httpProbe(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);
  try {
    final uri = Uri.parse(url);
    final req = await client.getUrl(uri);
    req.followRedirects = false;
    final res = await req.close().timeout(const Duration(seconds: 2));
    if (url.contains('generate_204')) {
      return res.statusCode == 204;
    }
    if (url.contains('cdn-cgi/trace')) {
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final body = await res.transform(SystemEncoding().decoder).join();
      return body.contains('ip=');
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _socketProbe(String host, int port) async {
  Socket? s;
  try {
    s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      s?.destroy();
    } catch (_) {}
  }
}
