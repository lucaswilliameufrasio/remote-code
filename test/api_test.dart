import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';

const machine = Machine(
    id: 'desktop',
    name: 'Desktop',
    url: 'https://desktop.example.ts.net',
    username: 'unit-test-user',
    password: 'unit-test-password',
    directories: ['/work/a']);

Json sessionJson(String id, String directory, int time) => {
      'id': id,
      'title': id,
      'projectID': 'prj_project',
      'cost': 0,
      'tokens': {},
      'time': {'created': time, 'updated': time},
      'location': {'directory': directory}
    };

void main() {
  group('OpenCode v2 API', () {
    test('Should paginate global sessions with opaque cursors', () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) {
          final rows = List.generate(
              100,
              (index) => sessionJson(
                  'ses_$index', '/unregistered/project', 1000 - index));
          return http.Response(
              jsonEncode({
                'data': rows,
                'cursor': {'next': 'cursor/opaque'}
              }),
              200);
        }
        return http.Response(jsonEncode({'data': [], 'cursor': {}}), 200);
      }));

      final page = await api.listAll(search: 'old checkout');
      expect(page.sessions.first.directory, '/unregistered/project');
      expect(page.cursor, 'cursor/opaque');
      await api.listAll(cursor: page.cursor);

      expect(requests.first.url.path, '/api/session');
      expect(requests.first.url.queryParameters['limit'], '100');
      expect(requests.first.url.queryParameters['order'], 'desc');
      expect(requests.first.url.queryParameters['search'], 'old checkout');
      expect(requests.first.url.queryParameters['directory'], isNull);
      expect(requests.last.url.queryParameters['cursor'], 'cursor/opaque');
      expect(requests.last.url.queryParameters['order'], isNull);
      expect(requests.first.headers['authorization'],
          'Basic ${base64Encode(utf8.encode('unit-test-user:unit-test-password'))}');
      api.close();
    });

    test('Should list sessions filtered by remote directory', () async {
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        expect(request.url.path, '/api/session');
        expect(request.url.queryParameters['directory'], '/work/a');
        expect(request.url.queryParameters['limit'], '500');
        return http.Response(
            jsonEncode({
              'data': [sessionJson('ses_existing', '/work/a', 10)],
              'cursor': {}
            }),
            200);
      }));

      final sessions = await api.listDirectory('/work/a', limit: 500);

      expect(sessions.single.id, 'ses_existing');
      expect(sessions.single.directory, '/work/a');
      api.close();
    });

    test('Should read server info and project lists from v2 routes', () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/info') {
          return http.Response(
              jsonEncode(
                  {'version': '2.0.0', 'pid': 42, 'urls': [], 'paths': {}}),
              200);
        }
        return http.Response(
            jsonEncode([
              {'id': 'prj_one', 'worktree': '/work/a'}
            ]),
            200);
      }));

      final health = await api.health();
      final projects = await api.projects();

      expect(health, {'healthy': true, 'version': '2.0.0'});
      expect(projects.single['id'], 'prj_one');
      expect(requests.map((request) => request.url.path),
          ['/api/info', '/api/project']);
      api.close();
    });

    test('Should map v2 locations when restoring and creating sessions',
        () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
              jsonEncode({
                'data': sessionJson('ses_existing', '/workspace/project-1', 10)
              }),
              200);
        }
        return http.Response(
            jsonEncode({'data': sessionJson('ses_created', '/work/a', 12)}),
            200);
      }));

      final restored = await api.getSession('ses_existing');
      final created = await api.createSession('/work/a', 'Mobile work');

      expect(restored.directory, '/workspace/project-1');
      expect(created.id, 'ses_created');
      expect(requests.first.url.path, '/api/session/ses_existing');
      expect(requests.last.url.path, '/api/session');
      expect(jsonDecode(requests.last.body), {
        'title': 'Mobile work',
        'location': {'directory': '/work/a'}
      });
      api.close();
    });

    test('Should switch agent and model before submitting a prompt', () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        return http.Response('', 204);
      }));
      final session = Session(
          id: 'ses_existing', title: 'Mobile work', directory: '/work/a');

      await api.prompt(session, 'continue',
          agent: 'build', model: {'id': 'gpt-5', 'providerID': 'openai'});

      expect(requests.map((request) => request.url.path), [
        '/api/session/ses_existing/agent',
        '/api/session/ses_existing/model',
        '/api/session/ses_existing/prompt'
      ]);
      expect(jsonDecode(requests[0].body), {'agent': 'build'});
      expect(jsonDecode(requests[1].body), {
        'model': {'id': 'gpt-5', 'providerID': 'openai'}
      });
      expect(jsonDecode(requests[2].body), {'text': 'continue'});
      api.close();
    });

    test('Should enqueue prompts with the v2 delivery mode', () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        return http.Response('', 204);
      }));
      const session = Session(
          id: 'ses_existing', title: 'Mobile work', directory: '/work/a');

      await api.prompt(session, 'Run after the current task',
          delivery: 'queue');

      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/api/session/ses_existing/prompt');
      expect(jsonDecode(requests.single.body),
          {'text': 'Run after the current task', 'delivery': 'queue'});
      api.close();
    });

    test('Should fall back to server-default agents when a location is empty',
        () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        final agents =
            request.url.queryParameters.containsKey('location[directory]')
                ? <Json>[]
                : <Json>[
                    {'id': 'build', 'name': 'Build', 'mode': 'primary'},
                    {'id': 'plan', 'name': 'Plan', 'mode': 'primary'}
                  ];
        return http.Response(jsonEncode({'data': agents}), 200);
      }));

      final agents = await api.agents('/work/a');

      expect(agents.map((agent) => agent['id']), ['build', 'plan']);
      expect(requests, hasLength(2));
      expect(
          requests.first.url.queryParameters['location[directory]'], '/work/a');
      expect(requests.last.url.queryParameters, isEmpty);
      api.close();
    });

    test('Should normalize recent v2 messages in chronological order',
        () async {
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        expect(request.url.path, '/api/session/ses_one/message');
        expect(request.url.queryParameters['order'], 'desc');
        return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'msg_idle',
                  'type': 'idle',
                  'outcome': 'succeeded',
                  'time': {'created': 3}
                },
                {
                  'id': 'msg_assistant',
                  'type': 'assistant',
                  'agent': 'build',
                  'model': {'id': 'gpt-5', 'providerID': 'openai'},
                  'time': {'created': 2},
                  'content': [
                    {'type': 'text', 'text': 'Starting'},
                    {'type': 'reasoning', 'text': 'Plan the work'},
                    {
                      'type': 'tool',
                      'id': 'tool_1',
                      'name': 'shell',
                      'state': {
                        'status': 'running',
                        'input': {'command': 'test'}
                      }
                    }
                  ]
                },
                {
                  'id': 'msg_user',
                  'type': 'user',
                  'text': 'Please build',
                  'time': {'created': 1}
                }
              ],
              'cursor': {}
            }),
            200);
      }));

      final messages = await api.messages(
          const Session(id: 'ses_one', title: 'One', directory: '/work/a'));

      expect(messages, hasLength(2));
      expect(object(messages.first['info'])['role'], 'user');
      final assistantParts = objects(messages.last['parts']);
      expect(assistantParts, hasLength(3));
      expect(assistantParts[0]['type'], 'reasoning');
      expect(assistantParts[0].containsKey('text'), isFalse);
      expect(assistantParts[1]['text'], 'Starting');
      expect(assistantParts[2]['tool'], 'shell');
      api.close();
    });

    test('Should unwrap location-scoped agent and model responses', () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/agent') {
          return http.Response(
              jsonEncode({
                'location': {'directory': '/work/a'},
                'data': [
                  {'id': 'build', 'name': 'Build', 'mode': 'primary'}
                ]
              }),
              200);
        }
        if (request.url.path == '/api/provider') {
          return http.Response(
              jsonEncode({
                'location': {'directory': '/work/a'},
                'data': [
                  {'id': 'openai', 'name': 'OpenAI', 'activation': 'enabled'}
                ]
              }),
              200);
        }
        return http.Response(
            jsonEncode({
              'location': {'directory': '/work/a'},
              'data': [
                {
                  'providerID': 'openai',
                  'modelID': 'gpt-5',
                  'name': 'GPT 5',
                  'enabled': true
                }
              ]
            }),
            200);
      }));

      final agents = await api.agents('/work/a');
      final providers = await api.providers('/work/a');

      expect(agents.single['id'], 'build');
      expect(objects(providers['providers']).single['id'], 'openai');
      expect(objects(providers['models']).single['modelID'], 'gpt-5');
      expect(
          requests.every((request) =>
              request.url.queryParameters['location[directory]'] == '/work/a'),
          isTrue);
      api.close();
    });

    test('Should load active sessions, permissions, and forms', () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/session/active') {
          return http.Response(
              jsonEncode({
                'data': {
                  'ses_one': {'type': 'running'}
                }
              }),
              200);
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/permission')) {
          return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'perm_one',
                    'sessionID': 'ses_one',
                    'action': 'shell',
                    'resources': ['git status'],
                    'metadata': {'tool': 'bash'}
                  }
                ]
              }),
              200);
        }
        if (request.method == 'GET') {
          return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'form_one',
                    'sessionID': 'ses_one',
                    'title': 'Choose a plan',
                    'fields': [
                      {'key': 'plan', 'type': 'string'}
                    ]
                  }
                ]
              }),
              200);
        }
        return http.Response('', 204);
      }));
      const session =
          Session(id: 'ses_one', title: 'One', directory: '/work/a');

      final statuses = await api.statuses();
      final permissions = await api.pending('permission', session);
      final forms = await api.pending('question', session);
      await api.permission(session, 'perm_one', 'once');
      await api.replyForm(session, 'form_one', {'plan': 'A'});

      expect(object(statuses['ses_one'])['type'], 'running');
      expect(permissions.single['permission'], 'shell');
      expect(permissions.single['patterns'], ['git status']);
      expect(forms.single['title'], 'Choose a plan');
      expect(requests[0].url.path, '/api/session/active');
      expect(requests[1].url.path, '/api/session/ses_one/permission');
      expect(requests[2].url.path, '/api/session/ses_one/form');
      expect(jsonDecode(requests[3].body), {'reply': 'once'});
      expect(requests[3].url.path,
          '/api/session/ses_one/permission/perm_one/reply');
      expect(jsonDecode(requests[4].body), {
        'answer': {'plan': 'A'}
      });
      expect(requests[4].url.path, '/api/session/ses_one/form/form_one/reply');
      api.close();
    });

    test('Should list, update, and cancel pending inbox items', () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'msg_queued',
                    'sessionID': 'ses_one',
                    'type': 'user',
                    'payload': {'text': 'Review the release notes'},
                    'delivery': 'queue'
                  }
                ]
              }),
              200);
        }
        return http.Response('', 204);
      }));
      const session =
          Session(id: 'ses_one', title: 'One', directory: '/work/a');

      final items = await api.inbox(session);
      await api.updateInboxDelivery(session, 'msg_queued', 'steer');
      await api.cancelInbox(session, 'msg_queued');

      expect(items.single['id'], 'msg_queued');
      expect(
          object(items.single['payload'])['text'], 'Review the release notes');
      expect(requests.map((request) => request.method),
          ['GET', 'PATCH', 'DELETE']);
      expect(requests.first.url.path, '/api/session/ses_one/inbox');
      expect(requests[1].url.path, '/api/session/ses_one/inbox/msg_queued');
      expect(jsonDecode(requests[1].body), {'delivery': 'steer'});
      expect(requests.last.url.path, '/api/session/ses_one/inbox/msg_queued');
      api.close();
    });

    test('Should send a persistent permission reply using the v2 contract',
        () async {
      http.Request? capturedRequest;
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 204);
      }));
      const session =
          Session(id: 'ses_one', title: 'One', directory: '/work/a');

      await api.permission(session, 'per_write', 'always');

      expect(capturedRequest?.url.path,
          '/api/session/ses_one/permission/per_write/reply');
      expect(jsonDecode(capturedRequest?.body ?? ''), {'reply': 'always'});
      api.close();
    });

    test('Should list MCP statuses and connect or disconnect a server',
        () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
              jsonEncode({
                'location': {'directory': '/work/a'},
                'data': [
                  {
                    'name': 'docs',
                    'status': {'status': 'connected'}
                  },
                  {
                    'name': 'tracker',
                    'status': {'status': 'disabled'}
                  }
                ]
              }),
              200);
        }
        return http.Response('', 204);
      }));

      final servers = await api.mcpServers('/work/a');
      await api.setMcpConnection('/work/a', 'tracker', connect: true);
      await api.setMcpConnection('/work/a', 'docs', connect: false);

      expect(servers, hasLength(2));
      expect(object(servers.first['status'])['status'], 'connected');
      expect(
          requests.map((request) => request.method), ['GET', 'POST', 'POST']);
      expect(
          requests.first.url.queryParameters['location[directory]'], '/work/a');
      expect(requests[1].url.path, '/api/mcp/tracker/connect');
      expect(requests[2].url.path, '/api/mcp/docs/disconnect');
      api.close();
    });

    test('Should list skills and activate one in a session', () async {
      final requests = <http.Request>[];
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
              jsonEncode({
                'location': {'directory': '/work/a'},
                'data': [
                  {'name': 'review', 'description': 'Review a proposed change'}
                ]
              }),
              200);
        }
        return http.Response('', 204);
      }));
      const session =
          Session(id: 'ses_one', title: 'One', directory: '/work/a');

      final skills = await api.skills('/work/a');
      await api.activateSkill(session, 'review');

      expect(skills.single['name'], 'review');
      expect(requests.first.url.path, '/api/skill');
      expect(
          requests.first.url.queryParameters['location[directory]'], '/work/a');
      expect(requests.last.url.path, '/api/session/ses_one/skill');
      expect(
          jsonDecode(requests.last.body), {'skill': 'review', 'resume': true});
      api.close();
    });

    test('Should not automatically retry a failed prompt', () async {
      var count = 0;
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        count++;
        throw http.ClientException('connection reset');
      }));

      await expectLater(
          api.prompt(
              const Session(id: 'ses_one', title: 'One', directory: '/work/a'),
              'make changes'),
          throwsA(isA<ApiException>()));

      expect(count, 1);
      api.close();
    });

    test('Should preserve authentication failures without legacy fallback',
        () async {
      var count = 0;
      final api = OpenCodeApi(machine, client: MockClient((request) async {
        count++;
        return http.Response('{}', 401);
      }));

      await expectLater(
          api.listAll(),
          throwsA(isA<ApiException>()
              .having((error) => error.status, 'status', 401)));

      expect(count, 1);
      api.close();
    });
  });
}
