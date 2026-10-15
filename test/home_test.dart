import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/home.dart';
import 'package:remote_dev/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('Should show a clear first-run path and separate destinations',
      (tester) async {
    final store = AppStore();
    await store.load();
    await store.security.completeWithoutProtection();

    await tester.pumpWidget(RemoteDevApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('Seu trabalho,\nsem interrupções.'), findsOneWidget);
    expect(find.text('Conecte seu ambiente'), findsOneWidget);
    expect(find.text('Configurar máquina'), findsOneWidget);

    await tester.tap(find.text('Configurar máquina'));
    await tester.pumpAndSettle();

    expect(find.text('SEUS AMBIENTES'), findsOneWidget);
    expect(find.text('Máquinas'), findsWidgets);
    expect(find.text('Conectar máquina'), findsOneWidget);
  });

  testWidgets(
      'Should show sessions created on the server in recent work and refresh on revisit',
      (tester) async {
    final store = AppStore();
    await store.load();
    await store.security.completeWithoutProtection();
    const machine = Machine(
      id: 'desktop',
      name: 'Desktop',
      url: 'https://desktop.example.ts.net',
      password: 'unit-test-password',
    );
    await store.putMachine(machine);
    var sessionListRequests = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          store: store,
          apiFactory: (selectedMachine) => OpenCodeApi(
            selectedMachine,
            client: MockClient((request) async {
              if (request.url.path == '/api/info') {
                return http.Response(jsonEncode({'version': '2.0.0'}), 200);
              }
              if (request.url.path == '/api/session') {
                sessionListRequests++;
                expect(request.url.queryParameters['limit'], '10');
                return http.Response(
                  jsonEncode({
                    'data': [
                      {
                        'id': 'ses_terminal',
                        'title': 'Created in terminal',
                        'time': {
                          'updated': DateTime.now().millisecondsSinceEpoch,
                        },
                        'location': {'directory': '/work/project'},
                      },
                    ],
                    'cursor': {},
                  }),
                  200,
                );
              }
              return http.Response('Unexpected route', 404);
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Created in terminal'), findsOneWidget);
    expect(store.bookmarks, isEmpty);
    expect(sessionListRequests, 1);

    await tester.tap(find.text('Máquinas').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trabalho'));
    await tester.pumpAndSettle();

    expect(sessionListRequests, 2);
    expect(find.text('Created in terminal'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should append ten sessions using the machine cursor',
      (tester) async {
    final requests = <http.Request>[];
    final store = await _showPaginatedHome(tester, (request) async {
      requests.add(request);
      final cursor = request.url.queryParameters['cursor'];
      expect(request.url.queryParameters['limit'], '10');
      if (cursor == null) {
        expect(request.url.queryParameters['order'], 'desc');
        return _sessionPage(0, 10, cursor: 'opaque/next+page');
      }
      expect(cursor, 'opaque/next+page');
      expect(request.url.queryParameters.containsKey('order'), isFalse);
      return _sessionPage(10, 10);
    });

    final loadMore = find.byKey(const ValueKey('load-more-sessions-desktop'));
    expect(find.text('10 recentes'), findsOneWidget);
    await tester.ensureVisible(loadMore);
    await tester.tap(loadMore);
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(find.text('20 recentes'), findsOneWidget);
    expect(find.text('Session 0'), findsOneWidget);
    expect(find.text('Session 19'), findsOneWidget);
    expect(loadMore, findsNothing);
    expect(store.bookmarks, isEmpty);

    await tester.tap(find.text('Máquinas').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trabalho'));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters.containsKey('cursor'), isFalse);
    expect(find.text('10 recentes'), findsOneWidget);
    expect(loadMore, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should keep loaded sessions and retry the same failed page',
      (tester) async {
    var pageAttempts = 0;
    await _showPaginatedHome(tester, (request) async {
      if (request.url.queryParameters['cursor'] == null) {
        return _sessionPage(0, 10, cursor: 'next-page');
      }
      expect(request.url.queryParameters['cursor'], 'next-page');
      pageAttempts++;
      if (pageAttempts == 1) {
        return http.Response('Unavailable', 503);
      }
      return _sessionPage(9, 2);
    });

    final loadMore = find.byKey(const ValueKey('load-more-sessions-desktop'));
    await tester.ensureVisible(loadMore);
    await tester.tap(loadMore);
    await tester.pumpAndSettle();
    expect(find.text('10 recentes'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(loadMore, findsOneWidget);

    await tester.ensureVisible(loadMore);
    await tester.tap(loadMore);
    await tester.pumpAndSettle();
    expect(pageAttempts, 2);
    expect(find.text('11 recentes'), findsOneWidget);
    expect(find.text('Session 9'), findsOneWidget);
    expect(find.text('Session 10'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsNothing);
    expect(loadMore, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

http.Response _sessionPage(int start, int count, {String? cursor}) {
  return http.Response(
    jsonEncode({
      'data': [
        for (var index = start; index < start + count; index++)
          {
            'id': 'ses_$index',
            'title': 'Session $index',
            'time': {'updated': 1000 - index},
            'location': {'directory': '/work/project'},
          },
      ],
      'cursor': {if (cursor != null) 'next': cursor},
    }),
    200,
  );
}

Future<AppStore> _showPaginatedHome(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) onSessions,
) async {
  await tester.binding.setSurfaceSize(const Size(800, 6000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final store = AppStore();
  await store.load();
  await store.putMachine(const Machine(
    id: 'desktop',
    name: 'Desktop',
    url: 'https://desktop.example.ts.net',
    password: 'unit-test-password',
  ));
  await tester.pumpWidget(MaterialApp(
    home: HomeScreen(
      store: store,
      apiFactory: (machine) => OpenCodeApi(
        machine,
        client: MockClient((request) async {
          if (request.url.path == '/api/info') {
            return http.Response(jsonEncode({'version': '2.0.0'}), 200);
          }
          if (request.url.path == '/api/session') {
            return onSessions(request);
          }
          return http.Response('Unexpected route', 404);
        }),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return store;
}
