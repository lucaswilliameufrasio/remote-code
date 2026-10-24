import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/remote_files.dart';

void main() {
  group('Remote filesystem v2', () {
    test('Should reject traversal absolute encoded and platform-specific paths',
        () {
      for (final path in [
        '../secret',
        'a/../b',
        '/etc/passwd',
        'a//b',
        './a',
        r'a\b',
        'C:secret',
        '%2e%2e/secret',
        'a\u0000b'
      ]) {
        expect(isProjectRelativePath(path), isFalse, reason: path);
      }
      expect(isProjectRelativePath('src/main file.dart'), isTrue);
      expect(isProjectRelativePath('', allowRoot: true), isTrue);
    });

    test(
        'Should list scoped files sort folders and hide outside-project entries',
        () async {
      final api = await _serve((request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/api/fs/list');
        expect(request.uri.queryParameters,
            {'location[directory]': '/work/project', 'path': 'src'});
        expect(request.headers.value('authorization'), startsWith('Basic '));
        request.response.write(jsonEncode({
          'location': {'directory': '/work/project'},
          'data': [
            {'path': 'src/z.dart', 'type': 'file'},
            {'path': '../outside', 'type': 'directory'},
            {'path': 'src/subfolder', 'type': 'directory'},
            {'path': '/etc', 'type': 'directory'},
          ]
        }));
      });
      final result = await api.listRemoteFiles('/work/project', path: 'src');
      expect(
          result.map((entry) => entry.path), ['src/subfolder', 'src/z.dart']);
      expect(result.first.isDirectory, isTrue);
    });

    test(
        'Should search recursively with a bounded result count and directory filter',
        () async {
      final api = await _serve((request) async {
        expect(request.uri.path, '/api/fs/find');
        expect(request.uri.queryParameters, {
          'location[directory]': '/work/project',
          'query': 'mobile',
          'limit': '100',
          'type': 'directory'
        });
        request.response.write(jsonEncode({
          'data': [
            {'path': 'src/mobile', 'type': 'directory'}
          ]
        }));
      });
      final result = await api.findRemoteFiles('/work/project', 'mobile',
          directoriesOnly: true);
      expect(result.single.path, 'src/mobile');
    });

    test('Should reject unsafe paths before making any HTTP request', () async {
      var calls = 0;
      final api = await _serve((request) async {
        calls++;
      });
      await expectLater(api.listRemoteFiles('/work/project', path: '../'),
          throwsA(isA<ApiException>()));
      await expectLater(api.readRemoteFile('/work/project', '/etc/passwd'),
          throwsA(isA<ApiException>()));
      expect(calls, 0);
    });

    test('Should read UTF-8 through the production client with a bounded Range',
        () async {
      final folder = await Directory.systemTemp.createTemp('remote-code-test-');
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/notes.txt');
      await file.writeAsString('Olá\nReview this project.');
      final api = await _serve((request) async {
        expect(request.uri.path, '/api/fs/read/src/notes%20file.txt');
        expect(request.uri.queryParameters['location[directory]'],
            '/work/project');
        expect(request.headers.value('range'), 'bytes=0-262144');
        request.response.add(await file.readAsBytes());
      });
      final preview =
          await api.readRemoteFile('/work/project', 'src/notes file.txt');
      expect(preview.text, 'Olá\nReview this project.');
      expect(preview.truncated, isFalse);
    });

    test('Should bound memory and show truncation when the host ignores Range',
        () async {
      final api = await _serve((request) async {
        request.response
            .add(List.filled(OpenCodeApi.filePreviewLimit + 100, 65));
      });
      final preview = await api.readRemoteFile('/work/project', 'large.txt');
      expect(preview.text.length, OpenCodeApi.filePreviewLimit);
      expect(preview.truncated, isTrue);
    });

    test('Should reject binary content without rendering it', () async {
      final api = await _serve((request) async {
        request.response.add([65, 0, 66]);
      });
      await expectLater(api.readRemoteFile('/work/project', 'binary'),
          throwsA(isA<ApiException>()));
    });

    test('Should mark a partial response as truncated from Content-Range',
        () async {
      final api = await _serve((request) async {
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 0-3/1000');
        request.response.write('text');
      });
      final preview = await api.readRemoteFile('/work/project', 'partial.txt');
      expect(preview.text, 'text');
      expect(preview.truncated, isTrue);
    });

    test(
        'Should reject a malformed structured diff rather than show misleading counts',
        () async {
      final api = await _serve((request) async {
        request.response.write(jsonEncode({
          'data': [
            {
              'file': 'file.txt',
              'patch': '',
              'status': 'modified',
              'additions': -1,
              'deletions': 0,
            }
          ]
        }));
      });
      await expectLater(
          api.sessionChanges(const Session(
              id: 'ses_test', title: 'Test', directory: '/work/project')),
          throwsA(isA<ApiException>()));
    });

    test('Should preserve server permission failures without retry', () async {
      var calls = 0;
      final api = await _serve((request) async {
        calls++;
        request.response.statusCode = 403;
      });
      await expectLater(
          api.readRemoteFile('/work/project', 'private.txt'),
          throwsA(isA<ApiException>()
              .having((exception) => exception.status, 'status', 403)));
      expect(calls, 1);
    });

    test('Should refuse redirects instead of forwarding file credentials',
        () async {
      var calls = 0;
      final api = await _serve((request) async {
        calls++;
        request.response.statusCode = 302;
        request.response.headers.set('location', '/destination');
      });
      await expectLater(api.readRemoteFile('/work/project', 'file.txt'),
          throwsA(isA<ApiException>()));
      expect(calls, 1);
    });

    test('Should reject malformed filesystem response types', () async {
      final api = await _serve((request) async {
        request.response.write(jsonEncode({
          'data': [
            {'path': 12, 'type': 'directory'}
          ]
        }));
      });
      await expectLater(
          api.listRemoteFiles('/work/project'), throwsA(isA<ApiException>()));
    });

    test('Should request a structured latest-turn diff with limited context',
        () async {
      final api = await _serve((request) async {
        expect(request.uri.path, '/api/session/ses_test/diff');
        expect(request.uri.queryParameters['context'], '3');
        request.response.write(jsonEncode({
          'data': [
            {
              'file': 'src/main.dart',
              'patch': '@@ -1 +1 @@\n-old\n+new',
              'additions': 1,
              'deletions': 1,
              'status': 'modified',
            }
          ]
        }));
      });
      final changes = await api.sessionChanges(const Session(
          id: 'ses_test', title: 'Test', directory: '/work/project'));
      expect(changes.single.additions, 1);
      expect(changes.single.file, 'src/main.dart');
    });
  });
}

Future<OpenCodeApi> _serve(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    await handler(request);
    await request.response.close();
  });
  final api = _NativeApi(Machine(
      id: 'local',
      name: 'Test',
      url: 'http://127.0.0.1:${server.port}',
      password: 'test-password'));
  addTearDown(api.close);
  return api;
}

// Preserve native API contract tests independently of the restricted RPC browser.
class _NativeApi extends OpenCodeApi {
  _NativeApi(super.machine);
  @override
  Future<List<RemoteFileEntry>> listRemoteFiles(String directory,
          {String path = ''}) =>
      listNativeRemoteFiles(directory, path: path);
  @override
  Future<List<RemoteFileEntry>> findRemoteFiles(String directory, String query,
          {bool directoriesOnly = false}) =>
      findNativeRemoteFiles(directory, query, directoriesOnly: directoriesOnly);
  @override
  Future<RemoteFilePreview> readRemoteFile(String directory, String path) =>
      readNativeRemoteFile(directory, path);
}
