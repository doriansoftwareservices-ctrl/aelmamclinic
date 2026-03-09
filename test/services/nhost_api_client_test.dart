import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aelmamclinic/services/nhost_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('storageUri normalizes duplicate slashes', () {
    final client = NhostApiClient(client: MockClient((_) async {
      return http.Response('{}', 200);
    }));

    final uri = client.storageUri('/files/test-id');
    expect(uri.path.endsWith('/files/test-id'), isTrue);
  });

  test('postJson sends JSON body and merges headers', () async {
    late http.Request captured;
    final client = NhostApiClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );

    final result = await client.postJson(
      Uri.parse('https://example.com/functions/test'),
      <String, dynamic>{'value': 7},
      headers: <String, String>{'x-test': '1'},
    );

    expect(result, equals(<String, dynamic>{'ok': true}));
    expect(captured.headers[HttpHeaders.contentTypeHeader], 'application/json');
    expect(captured.headers['x-test'], '1');
    expect(jsonDecode(captured.body), equals(<String, dynamic>{'value': 7}));
  });

  test('postJson exposes parsed server error when response is JSON', () async {
    final client = NhostApiClient(
      client: MockClient((_) async {
        return http.Response(
          jsonEncode(<String, dynamic>{'message': 'invalid token'}),
          401,
        );
      }),
    );

    expect(
      () => client.postJson(
        Uri.parse('https://example.com/functions/test'),
        <String, dynamic>{},
      ),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          contains('invalid token'),
        ),
      ),
    );
  });

  test('postJson falls back to raw response body when payload is not JSON', () async {
    final client = NhostApiClient(
      client: MockClient((_) async {
        return http.Response('gateway exploded', 502);
      }),
    );

    expect(
      () => client.postJson(
        Uri.parse('https://example.com/functions/test'),
        <String, dynamic>{},
      ),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          contains('gateway exploded'),
        ),
      ),
    );
  });
}
