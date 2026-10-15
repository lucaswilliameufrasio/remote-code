import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/features/pending_inbox.dart';

const testMachine = Machine(
  id: 'desktop',
  name: 'Desktop',
  url: 'https://desktop.example.ts.net',
  password: 'unit-test-password',
);

void main() {
  test('Should scan known locations and resolve their pending sessions',
      () async {
    final requests = <http.Request>[];
    final bookmarks = [
      Bookmark(
        machineID: testMachine.id,
        session: const Session(
          id: 'ses_saved',
          title: 'Saved session',
          directory: '/work/saved',
        ),
        opened: 100,
      ),
    ];
    final scanner = PendingInboxScanner(
      apiFactory: (machine) => OpenCodeApi(
        machine,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/info') {
            return http.Response(jsonEncode({'version': '2.0.0'}), 200);
          }
          if (request.url.path == '/api/session') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'ses_recent',
                    'title': 'Recent session',
                    'projectID': 'prj_recent',
                    'time': {'updated': 200},
                    'location': {'directory': '/work/recent'},
                  },
                ],
                'cursor': {},
              }),
              200,
            );
          }
          if (request.url.path == '/api/session/active') {
            return http.Response(
              jsonEncode({
                'data': {
                  'ses_saved': {'type': 'running'},
                  'ses_active': {'type': 'running'},
                },
              }),
              200,
            );
          }
          if (request.url.path == '/api/project') {
            return http.Response(
              jsonEncode([
                {
                  'id': 'prj_current',
                  'canonical': '/work/project',
                  'name': 'Project',
                },
              ]),
              200,
            );
          }
          if (request.url.path == '/api/session/ses_active' ||
              request.url.path == '/api/session/ses_older') {
            final sessionID = request.url.path.split('/').last;
            final directory =
                sessionID == 'ses_active' ? '/work/active' : '/work/project';
            return http.Response(
              jsonEncode({
                'data': {
                  'id': sessionID,
                  'title': sessionID,
                  'projectID': 'prj_active',
                  'location': {'directory': directory},
                },
              }),
              200,
            );
          }
          if (request.url.path == '/api/form') {
            final directory =
                request.url.queryParameters['location[directory]'];
            final forms = switch (directory) {
              '/work/saved' => [
                  {
                    'id': 'form_saved',
                    'sessionID': 'ses_saved',
                    'title': 'Choose a deployment target',
                    'fields': [
                      {'key': 'target', 'type': 'string', 'title': 'Target'},
                    ],
                  },
                ],
              '/work/project' => [
                  {
                    'id': 'form_older',
                    'sessionID': 'ses_older',
                    'title': 'Older unbookmarked request',
                    'fields': [],
                  },
                ],
              '/work/recent' => [
                  {
                    'id': 'form_recent',
                    'sessionID': 'ses_recent',
                    'title': 'Recent request',
                    'fields': [],
                  },
                ],
              _ => const [],
            };
            return http.Response(jsonEncode({'data': forms}), 200);
          }
          if (request.url.path == '/api/permission/request') {
            final directory =
                request.url.queryParameters['location[directory]'];
            final permissions = directory == '/work/active'
                ? [
                    {
                      'id': 'perm_active',
                      'sessionID': 'ses_active',
                      'action': 'shell',
                      'resources': ['git status'],
                    },
                  ]
                : const [];
            return http.Response(jsonEncode({'data': permissions}), 200);
          }
          return http.Response('Unexpected route', 404);
        }),
      ),
    );

    final result = await scanner.scan(
      machines: [testMachine],
      bookmarks: bookmarks,
    );

    expect(result.totalLocations, 5);
    expect(result.checkedLocations, 5);
    expect(result.actions, hasLength(4));
    expect(
      result.actions.map((action) => action.session.id).toSet(),
      {'ses_saved', 'ses_active', 'ses_older', 'ses_recent'},
    );
    expect(
      result.actions.map((action) => action.kind).toSet(),
      {PendingActionKind.question, PendingActionKind.permission},
    );
    expect(
      requests.where(
        (request) => request.url.path == '/api/session/ses_saved',
      ),
      isEmpty,
    );
    expect(
      requests.any(
        (request) => request.url.path == '/api/session/ses_older',
      ),
      isTrue,
    );
    expect(
      requests.any(
        (request) => request.url.path == '/api/session/ses_recent',
      ),
      isFalse,
    );
    expect(result.failures, 0);
    expect(result.truncated, isFalse);
  });

  test('Should report partial endpoint failures and keep scanning', () async {
    final scanner = PendingInboxScanner(
      apiFactory: (machine) => OpenCodeApi(
        machine,
        client: MockClient((request) async {
          if (request.url.path == '/api/info') {
            return http.Response(jsonEncode({'version': '2.0.0'}), 200);
          }
          if (request.url.path == '/api/session') {
            return http.Response(
              jsonEncode({'data': [], 'cursor': {}}),
              200,
            );
          }
          if (request.url.path == '/api/session/active') {
            return http.Response(jsonEncode({'data': {}}), 200);
          }
          if (request.url.path == '/api/project') {
            return http.Response(jsonEncode([]), 200);
          }
          if (request.url.path == '/api/form') {
            return http.Response(jsonEncode({'data': []}), 200);
          }
          if (request.url.path == '/api/permission/request' &&
              request.url.queryParameters['location[directory]'] ==
                  '/work/saved') {
            return http.Response('Unavailable', 503);
          }
          if (request.url.path == '/api/permission/request') {
            return http.Response(jsonEncode({'data': []}), 200);
          }
          return http.Response('Unexpected route', 404);
        }),
      ),
    );

    final result = await scanner.scan(
      machines: [testMachine],
      bookmarks: [
        Bookmark(
          machineID: testMachine.id,
          session: const Session(
            id: 'ses_saved',
            title: 'Saved session',
            directory: '/work/saved',
          ),
          opened: 100,
        ),
      ],
    );

    expect(result.checkedLocations, 2);
    expect(result.actions, isEmpty);
    expect(result.failures, 1);
    expect(result.machineErrors, hasLength(1));
  });

  test('Should cap unbookmarked active sessions and mark the scan truncated',
      () async {
    var sessionDetailsRequests = 0;
    final activeSessions = <String, Json>{};
    for (var sessionIndex = 0; sessionIndex < 21; sessionIndex++) {
      activeSessions['ses_${sessionIndex.toString().padLeft(2, '0')}'] = {
        'type': 'running',
      };
    }

    final scanner = PendingInboxScanner(
      apiFactory: (machine) => OpenCodeApi(
        machine,
        client: MockClient((request) async {
          if (request.url.path == '/api/info') {
            return http.Response(jsonEncode({'version': '2.0.0'}), 200);
          }
          if (request.url.path == '/api/session') {
            return http.Response(
              jsonEncode({'data': [], 'cursor': {}}),
              200,
            );
          }
          if (request.url.path == '/api/session/active') {
            return http.Response(jsonEncode({'data': activeSessions}), 200);
          }
          if (request.url.path == '/api/project') {
            return http.Response(jsonEncode([]), 200);
          }
          if (request.url.path.startsWith('/api/session/ses_') &&
              !request.url.path.endsWith('/form') &&
              !request.url.path.endsWith('/permission')) {
            sessionDetailsRequests++;
            final sessionID = request.url.path.split('/').last;
            return http.Response(
              jsonEncode({
                'data': {
                  'id': sessionID,
                  'title': sessionID,
                  'location': {'directory': '/work/$sessionID'},
                },
              }),
              200,
            );
          }
          if (request.url.path == '/api/form' ||
              request.url.path == '/api/permission/request') {
            return http.Response(jsonEncode({'data': []}), 200);
          }
          return http.Response('Unexpected route', 404);
        }),
      ),
    );

    final result = await scanner.scan(machines: [testMachine], bookmarks: []);

    expect(sessionDetailsRequests, 20);
    expect(result.totalLocations, 21);
    expect(result.checkedLocations, 21);
    expect(result.truncated, isTrue);
    expect(result.actions, isEmpty);
  });
}
