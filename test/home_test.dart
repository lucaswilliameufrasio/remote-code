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
}
