import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/chat.dart';
import 'package:remote_dev/features/pairing.dart';

const machine = Machine(
    id: 'fixture',
    name: 'Local fixture',
    url: 'https://fixture.example',
    password: 'synthetic');
const session = Session(
    id: 'ses_fixture', title: 'Mobile fixture', directory: '/fixture/project');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Should navigate from chat to restricted files and diff without sending a prompt',
      (tester) async {
    final fixture = _Fixture();
    await fixture.show(tester);
    await tester.tap(find.byTooltip('Ações da sessão'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arquivos do projeto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();
    expect(find.text('void main() {}'), findsOneWidget);
    await tester.tap(find.text('Inserir caminho no rascunho'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        contains('src/main.dart'));
    expect(fixture.prompts, 0);
    await tester.tap(find.byTooltip('Ações da sessão'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ver alterações'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src/main.dart'));
    await tester.pumpAndSettle();
    expect(find.text('+new'), findsOneWidget);
    expect(find.text('-old'), findsOneWidget);
    expect(fixture.nativeFilesystemCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Should recover a missing response by exact ID on the device without resending',
      (tester) async {
    final fixture = _Fixture();
    await fixture.show(tester);
    await tester.enterText(find.byType(TextField), 'Review fixture');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pumpAndSettle();
    expect(fixture.prompts, 1);
    expect(fixture.messageID, startsWith('msg_'));
    expect(find.text('Envio sem confirmação'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should require confirmation after a QR detection before pairing',
      (tester) async {
    final fixture = _Fixture();
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.push<String>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PairingScreen(
                                machine: machine,
                                apiFactory: (_) => fixture.api(),
                                scannerBuilder: (context, onScan) => TextButton(
                                    onPressed: () => onScan(
                                        'https://fixture.example/auth/connect/synthetic_code'),
                                    child: const Text('Detect fixture QR'))),
                          )),
                      child: const Text('Pair')),
                ))));
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Ler QR da mesma máquina'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ler QR da mesma máquina'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detect fixture QR'));
    await tester.pumpAndSettle();
    expect(fixture.redemptions, 0);
    await tester.ensureVisible(find.text('Confirmar destino e parear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmar destino e parear'));
    await tester.pumpAndSettle();
    expect(fixture.redemptions, 1);
    expect(find.text('Pair'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Fixture {
  int prompts = 0, nativeFilesystemCalls = 0, redemptions = 0;
  String messageID = '';

  Future<void> show(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            store: store,
            machine: machine,
            session: session,
            apiOverride: api())));
    await tester.pumpAndSettle();
  }

  OpenCodeApi api() => OpenCodeApi(machine, client: MockClient((request) async {
        final path = request.url.path;
        if (path.startsWith('/api/fs/')) {
          nativeFilesystemCalls++;
        }
        if (path.startsWith('/auth/connect/')) {
          redemptions++;
          return http.Response(
              jsonEncode({'token': 'synthetic-session-token'}), 200);
        }
        if (path == '/api/info') {
          return http.Response(jsonEncode({'version': '2.0.27'}), 200);
        }
        if (path.endsWith('/prompt')) {
          prompts++;
          messageID = object(jsonDecode(request.body))['id'] as String;
          return http.Response('{}', 503);
        }
        if (messageID.isNotEmpty && path.endsWith('/message/$messageID')) {
          return http.Response(
              jsonEncode({
                'data': {'id': messageID, 'type': 'user'}
              }),
              200);
        }
        if (path.endsWith('/remote-code-files-v1/list')) {
          final input = object(object(jsonDecode(request.body))['input']);
          return http.Response(
              jsonEncode({
                'output': {
                  'data': input['path'] == 'src'
                      ? [
                          {'path': 'src/main.dart', 'type': 'file'}
                        ]
                      : [
                          {'path': 'src', 'type': 'directory'}
                        ]
                }
              }),
              200);
        }
        if (path.endsWith('/remote-code-files-v1/read')) {
          return http.Response(
              jsonEncode({
                'output': {'text': 'void main() {}', 'truncated': false}
              }),
              200);
        }
        if (path.endsWith('/diff')) {
          return http.Response(
              jsonEncode({
                'data': [
                  {
                    'file': 'src/main.dart',
                    'patch': '@@ -1 +1 @@\n-old\n+new',
                    'status': 'modified',
                    'additions': 1,
                    'deletions': 1,
                  }
                ]
              }),
              200);
        }
        if (path == '/api/session/ses_fixture') {
          return http.Response(jsonEncode({'data': session.toJson()}), 200);
        }
        if (path == '/api/session/active') {
          return http.Response(jsonEncode({'data': {}}), 200);
        }
        return http.Response(jsonEncode({'data': [], 'cursor': {}}), 200);
      }));
}
