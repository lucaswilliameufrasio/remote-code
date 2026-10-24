import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/claude_api.dart';
import 'package:remote_dev/core/models.dart';

void main() {
  test('Should preserve old OpenCode machines and serialize the Claude backend',
      () {
    final original = Machine.fromJson({
      'id': 'legacy',
      'name': 'Computer',
      'url': 'https://host.example',
    });
    expect(original.backend, AgentBackend.openCode);
    final claude =
        Machine.fromJson({...original.toJson(), 'backend': 'claude_code'});
    expect(claude.withDirectory('/project').backend, AgentBackend.claudeCode);
    expect(claude.toJson()['backend'], 'claude_code');
    final api = OpenCodeApi.create(claude);
    addTearDown(api.close);
    expect(api, isA<ClaudeCodeApi>());
    expect(() => Machine.fromJson({...original.toJson(), 'backend': 'unknown'}),
        throwsFormatException);
  });

  test(
      'Should use the distinct Claude protocol and reconcile exact receipt IDs',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    final requests = <Map<String, dynamic>>[];
    final sessionData = {
      'id': 'session-id',
      'title': 'Claude session',
      'directory': '/project',
      'updated': 1,
      'external': false,
    };
    server.listen((request) async {
      paths.add(request.uri.path);
      expect(request.headers.value('authorization'),
          'Basic ${base64Encode(utf8.encode('coderelay:synthetic-password'))}');
      request.response.headers.contentType = ContentType.json;
      final Object response;
      if (request.uri.path.endsWith('/info')) {
        response = {
          'agent': 'claude_code',
          'protocol_version': 1,
          'healthy': true,
          'adapter_version': '1.0.0'
        };
      } else if (request.uri.path.endsWith('/active')) {
        response = {
          'data': {'session-id': 'running'}
        };
      } else if (request.uri.path.endsWith('/requests')) {
        response = {
          'data': [
            {
              'id': 'permission-id',
              'session_id': 'session-id',
              'permission': 'Bash',
              'patterns': ['fixture'],
              'persistent': false
            }
          ]
        };
      } else if (request.uri.path.endsWith('/sessions')) {
        response = {
          'data': [sessionData],
          'has_more': false
        };
      } else if (request.uri.path.endsWith('/messages')) {
        response = {
          'data': [
            {
              'id': 'native-message',
              'role': 'assistant',
              'parts': [
                {'type': 'text', 'text': 'Claude response'}
              ]
            }
          ],
          'has_more': false
        };
      } else if (request.uri.path.endsWith('/prompts')) {
        requests.add(Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map));
        response = {'id': 'msg_exact', 'state': 'admitted'};
      } else if (request.uri.path.endsWith('/receipts/msg_exact')) {
        response = {'id': 'msg_exact', 'state': 'completed'};
      } else if (request.uri.path.endsWith('/fork')) {
        requests.add(Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map));
        response = {...sessionData, 'id': 'fork-id'};
      } else {
        response = sessionData;
      }
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    final api = OpenCodeApi.create(Machine(
      id: 'claude',
      name: 'Claude',
      url: 'http://127.0.0.1:${server.port}',
      username: 'coderelay',
      password: 'synthetic-password',
      backend: AgentBackend.claudeCode,
    ));
    addTearDown(api.close);
    expect((await api.health())['healthy'], true);
    final session = (await api.listAll(limit: 10)).sessions.single;
    expect((await api.statuses())[session.id], {'type': 'running'});
    expect((await api.pendingForLocation('permission')).single['sessionID'],
        session.id);
    expect((await api.messages(session)).messages.single['info'],
        {'id': 'native-message', 'role': 'assistant'});
    await api.prompt(session, 'User text',
        messageID: 'msg_exact', model: {'id': 'sonnet'});
    expect(requests.first,
        {'id': 'msg_exact', 'text': 'User text', 'model': 'sonnet'});
    expect(await api.promptReceived(session, 'msg_exact'), true);
    expect((await api.forkSession(session)).id, 'fork-id');
    expect(requests.last, {'confirm_shared_files': true});
    expect(paths.every((path) => path.startsWith('/relay/v1/')), true);
    final count = paths.length;
    await expectLater(
        api.request('GET', '/api/info'), throwsA(isA<ApiException>()));
    await expectLater(api.permission(session, 'permission', 'always'),
        throwsA(isA<ApiException>()));
    await expectLater(
        api.prompt(session, 'queued',
            messageID: 'msg_queued', delivery: 'queue'),
        throwsA(isA<ApiException>()));
    expect(paths.length, count);
  });

  test(
      'Should refuse a server that does not identify the Claude adapter protocol',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write(jsonEncode({'version': '2.1.2', 'healthy': true}));
      await request.response.close();
    });
    final api = OpenCodeApi.create(Machine(
      id: 'wrong-agent',
      name: 'Wrong',
      url: 'http://127.0.0.1:${server.port}',
      password: 'synthetic',
      backend: AgentBackend.claudeCode,
    ));
    addTearDown(api.close);
    await expectLater(api.health(), throwsA(isA<ApiException>()));
  });
}
