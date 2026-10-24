import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';

void main() {
  group('Restricted file browser RPC', () {
    test('Should obtain configured roots without browsing the default location',
        () async {
      final api = await _serve((request) async {
        expect(request.uri.path, '/api/rpc/remote-code-files-v1/roots');
        expect(request.uri.queryParameters, isEmpty);
        request.response.write(jsonEncode({
          'output': {
            'data': ['/work/allowed']
          }
        }));
      });
      expect(await api.allowedFileRoots(), ['/work/allowed']);
    });
    test(
        'Should use only the authenticated host RPC and the requested location',
        () async {
      final api = await _serve((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/rpc/remote-code-files-v1/read');
        expect(request.uri.queryParameters['location[directory]'], '/work');
        expect(request.headers.value('authorization'), startsWith('Basic '));
        expect(jsonDecode(await utf8.decoder.bind(request).join()), {
          'input': {'path': 'file.txt'}
        });
        request.response.write(jsonEncode({
          'output': {'text': 'safe', 'truncated': false}
        }));
      });
      expect((await api.readRemoteFile('/work', 'file.txt')).text, 'safe');
    });

    test(
        'Should fail closed when the plugin is absent without trying native filesystem routes',
        () async {
      var calls = 0;
      final api = await _serve((request) async {
        calls++;
        expect(request.uri.path, startsWith('/api/rpc/remote-code-files-v1/'));
        request.response.statusCode = 400;
        request.response
            .write(jsonEncode({'_tag': 'RpcError', 'type': 'rpc.unavailable'}));
      });
      await expectLater(
          api.listRemoteFiles('/work'),
          throwsA(isA<ApiException>().having((exception) => exception.message,
              'installation guidance', contains('Instale a extensão'))));
      expect(calls, 1);
    });

    test(
        'Should map owned error codes without displaying arbitrary host messages',
        () async {
      final api = await _serve((request) async {
        request.response.statusCode = 400;
        request.response.write(jsonEncode({
          '_tag': 'RpcError',
          'type': 'rejected',
          'message': 'private details not to display',
          'data': {'code': 'FILES_BINARY'}
        }));
      });
      await expectLater(
          api.readRemoteFile('/work', 'binary'),
          throwsA(isA<ApiException>().having(
              (exception) => exception.message,
              'safe error',
              'Visualização disponível somente para texto UTF-8.')));
    });

    test(
        'Should reject an oversized preview even if the server violates its limit',
        () async {
      final api = await _serve((request) async {
        request.response.write(jsonEncode({
          'output': {
            'text': 'x' * (OpenCodeApi.filePreviewLimit + 1),
            'truncated': false
          }
        }));
      });
      await expectLater(
          api.readRemoteFile('/work', 'large'), throwsA(isA<ApiException>()));
    });

    test('Should validate entries from the restricted listing', () async {
      final api = await _serve((request) async {
        expect(request.uri.path, '/api/rpc/remote-code-files-v1/list');
        request.response.write(jsonEncode({
          'output': {
            'data': [
              {'path': 'src', 'type': 'directory'},
              {'path': '../outside', 'type': 'directory'},
            ]
          }
        }));
      });
      expect((await api.listRemoteFiles('/work')).single.path, 'src');
    });
  });
}

Future<OpenCodeApi> _serve(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    try {
      await handler(request);
    } finally {
      await request.response.close();
    }
  });
  final api = OpenCodeApi(Machine(
      id: 'test',
      name: 'Test',
      url: 'http://127.0.0.1:${server.port}',
      password: 'test'));
  addTearDown(api.close);
  return api;
}
