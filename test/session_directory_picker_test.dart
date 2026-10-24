import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/session_directory_picker.dart';
import 'package:remote_dev/features/sessions.dart';

const machine = Machine(
  id: 'desktop',
  name: 'Desktop',
  url: 'https://desktop.example.ts.net',
  password: 'unit-test-password',
  directories: ['/work/saved'],
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('Should load authorized roots only after the user requests them',
      (tester) async {
    final store = AppStore();
    await store.load();
    final requests = <http.Request>[];
    await tester.pumpWidget(MaterialApp(
        home: SessionDirectoryPicker(
            store: store,
            machine: machine,
            apiFactory: (machine) => _api(machine, requests: requests))));
    await tester.pumpAndSettle();
    expect(find.text('/work/allowed'), findsNothing);
    await tester.tap(find.text('Carregar raízes autorizadas do host'));
    await tester.pumpAndSettle();
    expect(find.text('/work/allowed'), findsOneWidget);
    expect(requests.where((request) => request.method == 'POST'), hasLength(1));
  });

  testWidgets('Should suggest projects and recent folders without duplicates',
      (tester) async {
    final store = AppStore();
    await store.load();
    String? selectedDirectory;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return Scaffold(
        body: TextButton(
          onPressed: () async {
            selectedDirectory = await showDialog<String>(
              context: context,
              builder: (_) => SessionDirectoryPicker(
                store: store,
                machine: machine,
                apiFactory: _api,
              ),
            );
          },
          child: const Text('Choose'),
        ),
      );
    })));
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    expect(find.text('/work/saved'), findsOneWidget);
    expect(find.text('Project Alpha'), findsOneWidget);
    expect(find.text('/work/alpha'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    expect(find.text('/work/saved'), findsNothing);
    await tester.tap(find.text('Project Alpha'));
    await tester.pumpAndSettle();
    expect(selectedDirectory, '/work/alpha');
    expect(store.bookmarks, isEmpty);
  });

  testWidgets('Should retain saved folders when remote suggestions fail',
      (tester) async {
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(MaterialApp(
      home: SessionDirectoryPicker(
        store: store,
        machine: machine,
        apiFactory: (machine) => OpenCodeApi(machine,
            client: MockClient((_) async => http.Response('Unavailable', 503))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('/work/saved'), findsOneWidget);
    expect(find.textContaining('Algumas sugestões'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '/work/new-folder');
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('Should offer folders when starting a session and allow cancel',
      (tester) async {
    final store = AppStore();
    await store.load();
    final requests = <http.Request>[];
    await tester.pumpWidget(MaterialApp(
      home: SessionsScreen(
        store: store,
        machine: machine,
        apiFactory: (machine) => _api(machine, requests: requests),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nova sessão'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionDirectoryPicker), findsOneWidget);
    await tester.tap(find.text('Project Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Nome da sessão'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(store.bookmarks, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

OpenCodeApi _api(Machine machine, {List<http.Request>? requests}) {
  return OpenCodeApi(machine, client: MockClient((request) async {
    requests?.add(request);
    if (request.url.path == '/api/rpc/remote-code-files-v1/roots') {
      return http.Response(
          jsonEncode({
            'output': {
              'data': ['/work/allowed']
            }
          }),
          200);
    }
    if (request.url.path == '/api/project') {
      return http.Response(
          jsonEncode([
            {
              'id': 'prj_alpha',
              'canonical': '/work/alpha',
              'name': 'Project Alpha'
            },
          ]),
          200);
    }
    if (request.url.path == '/api/session') {
      return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'ses_recent',
                'title': 'Recent',
                'location': {'directory': '/work/alpha/'},
              },
            ],
            'cursor': {'next': null, 'previous': null},
          }),
          200);
    }
    return http.Response('Unexpected route', 404);
  }));
}
