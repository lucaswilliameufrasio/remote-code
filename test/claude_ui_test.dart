import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/chat.dart';
import 'package:remote_dev/features/home.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const machine = Machine(
      id: 'claude',
      name: 'Computer',
      url: 'https://claude.example',
      username: 'coderelay',
      password: 'synthetic',
      backend: AgentBackend.claudeCode);

  testWidgets(
      'Should expose Claude selection and discard credentials on backend change',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(MaterialApp(home: MachineEditor(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<AgentBackend>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code').last);
    await tester.pumpAndSettle();
    expect(find.text('URL do adaptador Claude Code'), findsOneWidget);
    expect(find.text('Usar código temporário de pareamento'), findsNothing);
    await tester.scrollUntilVisible(find.text('Usuário'), 200,
        scrollable: find.byType(Scrollable).first);
    final fields =
        tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    expect(fields.any((field) => field.controller?.text == 'coderelay'), true);
  });

  testWidgets(
      'Should display external history as read only and require fork confirmation',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    var forks = 0;
    final api = OpenCodeApi.create(machine, client: MockClient((request) async {
      Object response = {'data': []};
      if (request.url.path.endsWith('/sessions/external')) {
        response = {
          'id': 'external',
          'title': 'External history',
          'directory': '/project',
          'updated': 1,
          'external': true
        };
      } else if (request.url.path.endsWith('/active')) {
        response = {'data': {}};
      } else if (request.url.path.endsWith('/messages')) {
        response = {'data': [], 'has_more': false};
      } else if (request.url.path.endsWith('/fork')) {
        forks++;
      }
      return http.Response(jsonEncode(response), 200);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            store: store,
            machine: machine,
            session: const Session(
                id: 'external',
                title: 'External history',
                directory: '/project',
                external: true),
            apiOverride: api)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Enviar mensagem'), findsNothing);
    expect(find.text('Continuar no CodeRelay'), findsOneWidget);
    await tester.tap(find.text('Continuar no CodeRelay'));
    await tester.pumpAndSettle();
    expect(find.text('Continuar em uma cópia do histórico?'), findsOneWidget);
    expect(forks, 0);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(forks, 0);
    await tester.tap(find.byTooltip('Ações da sessão'));
    await tester.pumpAndSettle();
    expect(find.text('Arquivos do projeto'), findsNothing);
    expect(find.text('Ferramentas e skills'), findsNothing);
    expect(find.text('Ver alterações'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
