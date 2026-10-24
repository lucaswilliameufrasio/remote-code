import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/attachments.dart';
import 'package:remote_dev/core/models.dart';

void main() {
  test('Should send real HTTP v2 inline files and preserve queue delivery',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = <Json>[];
    server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/session/ses_test/prompt');
      expect(request.headers.contentType?.mimeType, 'application/json');
      expect(request.headers.value('authorization'), startsWith('Basic '));
      received.add(object(jsonDecode(await utf8.decoder.bind(request).join())));
      request.response.statusCode = 200;
      request.response.write(jsonEncode({'data': {}}));
      await request.response.close();
    });
    final api = OpenCodeApi(Machine(
        id: 'test',
        name: 'Test',
        url: 'http://127.0.0.1:${server.port}',
        password: 'test-password'));
    addTearDown(api.close);
    const session =
        Session(id: 'ses_test', title: 'Test', directory: '/work/test');
    final file = PromptAttachment.fromBytes(
        'notes.txt', Uint8List.fromList(utf8.encode('hello')));
    await api.prompt(session, '', delivery: 'queue', attachments: [file]);
    expect(received.single, {
      'text': '',
      'delivery': 'queue',
      'files': [
        {'uri': 'data:text/plain;base64,aGVsbG8=', 'name': 'notes.txt'}
      ],
    });
  });

  test('Should resolve the current session model before checking media support',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/api/session/ses_test') {
        request.response.write(jsonEncode({
          'data': {
            'model': {'id': 'current-model', 'providerID': 'test'},
          }
        }));
      } else {
        expect(
            request.uri.queryParameters['location[directory]'], '/work/test');
        request.response.write(jsonEncode({
          'data': [
            {'modelID': 'other-model', 'providerID': 'test'},
            {
              'modelID': 'current-model',
              'providerID': 'test',
              'capabilities': {
                'input': ['text', 'image', 'pdf']
              }
            },
          ]
        }));
      }
      await request.response.close();
    });
    final api = _api(server);
    addTearDown(api.close);
    final model = await api.attachmentModel(_session);
    expect(model['modelID'], 'current-model');
    expect(paths, ['/api/session/ses_test', '/api/model']);
  });

  test(
      'Should check an explicitly selected model without using the session default',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.uri.path, '/api/model');
      request.response.write(jsonEncode({
        'data': [
          {
            'modelID': 'chosen-model',
            'providerID': 'test',
            'capabilities': {
              'input': ['text', 'pdf']
            }
          },
        ]
      }));
      await request.response.close();
    });
    final api = _api(server);
    addTearDown(api.close);
    final model = await api.attachmentModel(_session,
        selectedModel: {'id': 'chosen-model', 'providerID': 'test'});
    expect(model['modelID'], 'chosen-model');
  });

  test('Should fail closed when there is no default media-compatible model',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write(jsonEncode(
          {'data': request.uri.path.endsWith('/default') ? null : {}}));
      await request.response.close();
    });
    final api = _api(server);
    addTearDown(api.close);
    await expectLater(
        api.attachmentModel(_session), throwsA(isA<ApiException>()));
  });
}

const _session =
    Session(id: 'ses_test', title: 'Test', directory: '/work/test');

OpenCodeApi _api(HttpServer server) => OpenCodeApi(Machine(
      id: 'test',
      name: 'Test',
      url: 'http://127.0.0.1:${server.port}',
      password: 'test-password',
    ));
