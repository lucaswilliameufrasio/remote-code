import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';

const _session = Session(id: 'ses_test', title: 'Test', directory: '/work');

void main() {
  group('Prompt receipt by exact identifier', () {
    test(
        'Should retain uncertainty when a success response acknowledges another ID',
        () async {
      final api = await _serve((request) async {
        request.response.write(jsonEncode({
          'data': {'id': 'msg_other', 'type': 'user'}
        }));
      });
      await expectLater(api.prompt(_session, 'Review', messageID: 'msg_test'),
          throwsA(isA<ApiException>()));
    });
    test('Should submit the chosen message ID in the v2 prompt contract',
        () async {
      final api = await _serve((request) async {
        expect(request.method, 'POST');
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(body, {'text': 'Review', 'id': 'msg_test'});
        request.response.write(jsonEncode({
          'data': {'id': 'msg_test', 'type': 'user'}
        }));
      });
      await api.prompt(_session, 'Review', messageID: 'msg_test');
    });

    test('Should confirm an exact delivered user message without resubmission',
        () async {
      var requests = 0;
      final api = await _serve((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.uri.path, '/api/session/ses_test/message/msg_test');
        request.response.write(jsonEncode({
          'data': {'id': 'msg_test', 'type': 'user'}
        }));
      });
      expect(await api.promptReceived(_session, 'msg_test'), isTrue);
      expect(requests, 1);
    });

    test('Should confirm a queued prompt by its exact ID after a history miss',
        () async {
      final api = await _serve((request) async {
        expect(request.method, 'GET');
        if (request.uri.path.endsWith('/inbox')) {
          request.response.write(jsonEncode({
            'data': [
              {'id': 'msg_test', 'type': 'user'}
            ]
          }));
        } else {
          request.response.statusCode = 404;
        }
      });
      expect(await api.promptReceived(_session, 'msg_test'), isTrue);
    });

    test(
        'Should not treat another message or matching text as proof of admission',
        () async {
      final api = await _serve((request) async {
        if (request.uri.path.endsWith('/inbox')) {
          request.response.write(jsonEncode({
            'data': [
              {
                'id': 'msg_other',
                'type': 'user',
                'payload': {'text': 'Review'}
              }
            ]
          }));
        } else {
          request.response.statusCode = 404;
        }
      });
      expect(await api.promptReceived(_session, 'msg_test'), isFalse);
    });

    test(
        'Should retain uncertainty on a malformed receipt or authorization failure',
        () async {
      final api = await _serve((request) async {
        request.response.write(jsonEncode({
          'data': {'id': 'msg_other', 'type': 'user'}
        }));
      });
      await expectLater(api.promptReceived(_session, 'msg_test'),
          throwsA(isA<ApiException>()));
    });
  });
}

Future<OpenCodeApi> _serve(Future<void> Function(HttpRequest) handle) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    try {
      await handle(request);
    } finally {
      await request.response.close();
    }
  });
  final api = OpenCodeApi(Machine(
      id: 'test',
      name: 'Test',
      url: 'http://127.0.0.1:${server.port}',
      password: 'test-password'));
  addTearDown(api.close);
  return api;
}
