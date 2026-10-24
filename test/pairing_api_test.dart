import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';

const _machine = Machine(
    id: 'test', name: 'Test', url: 'https://test.example.ts.net', password: '');

void main() {
  group('OpenCode v2 pairing', () {
    test(
        'Should redeem once on the confirmed host and verify the token with v2 health',
        () async {
      final calls = <String>[];
      final api = await _server((request) async {
        calls.add(request.uri.path);
        expect(request.headers.value('accept'), 'application/json');
        if (request.uri.path.startsWith('/auth/connect/')) {
          expect(request.headers.value('authorization'), isNull);
          request.response
              .write(jsonEncode({'token': 'synthetic-session-token'}));
        } else {
          expect(request.headers.value('authorization'),
              'Basic ${base64Encode(utf8.encode('opencode:synthetic-session-token'))}');
          request.response.write(jsonEncode({'version': '2.0.29'}));
        }
      });
      expect(await api.redeemPairingCode('synthetic_code'),
          'synthetic-session-token');
      expect(calls, ['/auth/connect/synthetic_code', '/api/info']);
    });

    test('Should refuse a redirect without forwarding pairing data or retrying',
        () async {
      var calls = 0;
      final api = await _server((request) async {
        calls++;
        request.response.statusCode = 302;
        request.response.headers
            .set('location', 'https://other.example/auth/connect/code');
      });
      await expectLater(api.redeemPairingCode('synthetic_code'),
          throwsA(isA<ApiException>()));
      expect(calls, 1);
    });

    test('Should reject unsafe origins and code URLs before sending a request',
        () async {
      for (final address in [
        'http://test.example',
        'https://user:password@test.example',
        'https://test.example/path',
        'https://test.example?destination=other'
      ]) {
        final api = OpenCodeApi(
            Machine(id: 'test', name: 'Test', url: address, password: ''));
        addTearDown(api.close);
        await expectLater(api.redeemPairingCode('synthetic_code'),
            throwsA(isA<ApiException>()));
      }
      final api = OpenCodeApi(_machine);
      addTearDown(api.close);
      await expectLater(
          api.redeemPairingCode('https://other.example/auth/connect/code'),
          throwsA(isA<ApiException>()));
    });

    test('Should reject non-v2 health before returning any token', () async {
      final api = await _server((request) async {
        request.response.write(jsonEncode(request.uri.path == '/api/info'
            ? {'version': '1.2.0'}
            : {'token': 'synthetic-session-token'}));
      });
      await expectLater(api.redeemPairingCode('synthetic_code'),
          throwsA(isA<ApiException>()));
    });

    test(
        'Should handle expired codes without retry or exposing response contents',
        () async {
      var calls = 0;
      final api = await _server((request) async {
        calls++;
        request.response.statusCode = 401;
        request.response.write('private-response-do-not-display');
      });
      await expectLater(
          api.redeemPairingCode('synthetic_code'),
          throwsA(isA<ApiException>().having(
              (exception) => exception.message,
              'safe message',
              isNot(contains('private-response-do-not-display')))));
      expect(calls, 1);
    });
  });
}

Future<OpenCodeApi> _server(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    try {
      await handler(request);
    } finally {
      await request.response.close();
    }
  });
  final api = OpenCodeApi(_machine, client: _LoopbackTransport(server.port));
  addTearDown(api.close);
  return api;
}

// Keep production origin validation while exercising HTTP against an isolated local server.
class _LoopbackTransport extends http.BaseClient {
  final int port;
  final client = http.Client();
  _LoopbackTransport(this.port);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    expect(request.url.origin, _machine.url);
    final local = http.Request(request.method,
        request.url.replace(scheme: 'http', host: '127.0.0.1', port: port))
      ..followRedirects = request.followRedirects
      ..headers.addAll(request.headers);
    return client.send(local);
  }

  @override
  void close() => client.close();
}
