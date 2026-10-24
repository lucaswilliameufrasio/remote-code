import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:integration_test/integration_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/attachments.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/chat.dart';
import 'package:remote_dev/features/file_changes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const serverUrl = String.fromEnvironment('LOCAL_E2E_URL');
  const project = String.fromEnvironment('LOCAL_E2E_PROJECT');
  const outside = String.fromEnvironment('LOCAL_E2E_OUTSIDE');
  const certificate = String.fromEnvironment('LOCAL_E2E_CA');
  const machine = Machine(
    id: 'isolated-real-server',
    name: 'Local OpenCode',
    url: serverUrl,
    password: 'synthetic-local-test-password',
  );

  OpenCodeApi apiFor(Machine target) {
    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(base64Decode(certificate));
    return OpenCodeApi(target, client: IOClient(HttpClient(context: context)));
  }

  testWidgets('Should authenticate and enforce real host filesystem boundaries',
      (tester) async {
    final api = apiFor(machine);
    addTearDown(api.close);
    final untrusted = OpenCodeApi(machine);
    addTearDown(untrusted.close);
    await expectLater(untrusted.health(), throwsA(isA<HandshakeException>()));
    expect((await api.health())['version'], startsWith('2.'));
    final unauthorized = apiFor(const Machine(
      id: 'wrong-password',
      name: 'Rejected',
      url: serverUrl,
      password: 'wrong-synthetic-password',
    ));
    addTearDown(unauthorized.close);
    await expectLater(
        unauthorized.health(),
        throwsA(isA<ApiException>()
            .having((error) => error.status, 'status', 401)));
    expect(await api.allowedFileRoots(directory: project), [project]);
    expect((await api.listRemoteFiles(project)).map((entry) => entry.path),
        contains('src'));
    expect((await api.readRemoteFile(project, 'src/fixture.txt')).text,
        'old fixture line\n');
    await expectLater(api.readRemoteFile(project, 'escape/private.txt'),
        throwsA(isA<ApiException>()));
    await expectLater(
        api.listRemoteFiles(outside), throwsA(isA<ApiException>()));
    await expectLater(
        api.readRemoteFile(project, 'binary.bin'),
        throwsA(isA<ApiException>()
            .having((error) => error.code, 'code', 'FILES_BINARY')));
  });

  testWidgets(
      'Should browse real files and reconcile an admitted prompt without resending',
      (tester) async {
    final api = apiFor(machine);
    final session =
        await api.createSession(project, 'Local real mobile validation');
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            store: store,
            machine: machine,
            session: session,
            apiOverride: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ações da sessão'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arquivos do projeto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fixture.txt'));
    await tester.pumpAndSettle();
    expect(find.text('old fixture line\n'), findsOneWidget);
    await tester.tap(find.text('Inserir caminho no rascunho'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        contains('src/fixture.txt'));
    await tester.enterText(find.byType(TextField), 'LOCAL_DROP_ACK');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pumpAndSettle();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final history = await api.messages(session);
      if (jsonEncode(history.messages).contains('LOCAL_RESPONSE_OK')) {
        break;
      }
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
    }
    expect(jsonEncode((await api.messages(session)).messages),
        contains('LOCAL_RESPONSE_OK'));
    expect(find.text('Envio sem confirmação'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty);
    final state = object(await api.request('GET', '/__test__/state'));
    expect(state['prompt_posts'], 1);
    expect(state['dropped_acks'], 1);
    expect(state['model_requests'], greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('Should submit an attachment and display a real snapshot diff',
      (tester) async {
    final api = apiFor(machine);
    addTearDown(api.close);
    final session =
        await api.createSession(project, 'Real snapshot validation');
    final attachment = PromptAttachment.fromBytes('notes.txt',
        Uint8List.fromList(utf8.encode('LOCAL_ATTACHMENT_CONTENT')));
    await api
        .prompt(session, 'LOCAL_CHANGE_FIXTURE', attachments: [attachment]);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var found = false;
    while (DateTime.now().isBefore(deadline)) {
      final changes = await api.sessionChanges(session);
      found =
          changes.any((change) => change.patch.contains('+new fixture line'));
      if (found) {
        break;
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
    }
    expect(found, isTrue,
        reason: jsonEncode({
          'state': await api.request('GET', '/__test__/state'),
          'messages': (await api.messages(session)).messages,
          'changes': (await api.sessionChanges(session))
              .map((change) => change.patch)
              .toList(),
        }));
    expect(jsonEncode((await api.messages(session)).messages),
        contains('notes.txt'));
    await tester.pumpWidget(
        MaterialApp(home: FileChangesScreen(api: api, session: session)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src/fixture.txt'));
    await tester.pumpAndSettle();
    expect(find.text('+new fixture line'), findsOneWidget);
    expect(find.text('-old fixture line'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
