import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:integration_test/integration_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/chat.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('CLAUDE_E2E_URL');
  const project = String.fromEnvironment('CLAUDE_E2E_PROJECT');
  const certificate = String.fromEnvironment('CLAUDE_E2E_CA');
  const externalID = String.fromEnvironment('CLAUDE_E2E_EXTERNAL');
  const machine = Machine(
    id: 'claude-local-e2e',
    name: 'Claude local',
    url: url,
    username: 'coderelay',
    password: 'synthetic-loopback-adapter-password',
    backend: AgentBackend.claudeCode,
  );

  OpenCodeApi apiFor(Machine target) {
    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(base64Decode(certificate));
    return OpenCodeApi.create(target,
        client: IOClient(HttpClient(context: context)));
  }

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (condition()) {
        return;
      }
    }
    fail('The expected Claude UI state did not appear within 25 seconds');
  }

  testWidgets(
      'Should confirm the Claude adapter and fork external history before sending',
      (tester) async {
    final api = apiFor(machine);
    addTearDown(api.close);
    expect((await api.health())['healthy'], true);
    final external = await api.getSession(externalID);
    expect(external.external, true);
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            store: store,
            machine: machine,
            session: external,
            apiFactory: apiFor)));
    await until(tester,
        () => find.text('Continuar no CodeRelay').evaluate().isNotEmpty);
    expect(find.byTooltip('Enviar mensagem'), findsNothing);
    await tester.tap(find.text('Continuar no CodeRelay'));
    await tester.pumpAndSettle();
    expect(find.text('Continuar em uma cópia do histórico?'), findsOneWidget);
    await tester.tap(find.text('Criar continuação'));
    await until(
        tester, () => find.byTooltip('Enviar mensagem').evaluate().isNotEmpty);
    expect(find.text('Anexar arquivo'), findsNothing);
    await tester.enterText(
        find.byType(TextField), 'Continue this local fixture');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await until(
        tester,
        () =>
            find.textContaining('CLAUDE_LOCAL_RESPONSE_OK').evaluate().length >=
                2 &&
            find.text('Trabalhando na máquina remota').evaluate().isEmpty);
    expect((await api.getSession(externalID)).external, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should deny a real SDK permission from the mobile chat',
      (tester) async {
    final api = apiFor(machine);
    final session = await api.createSession(project, 'Mobile Claude approval');
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            store: store,
            machine: machine,
            session: session,
            apiOverride: api)));
    await until(
        tester, () => find.byTooltip('Enviar mensagem').evaluate().isNotEmpty);
    await tester.enterText(
        find.byType(TextField), 'REQUEST_PERMISSION_FIXTURE');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await until(tester, () => find.text('Uma vez').evaluate().isNotEmpty);
    expect(find.text('Sempre permitir'), findsNothing);
    await tester.tap(find.text('Negar'));
    await until(
        tester,
        () => find
            .textContaining('CLAUDE_LOCAL_RESPONSE_OK')
            .evaluate()
            .isNotEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
