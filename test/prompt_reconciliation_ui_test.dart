import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/prompt_attempt.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/chat.dart';

const _machine = Machine(
    id: 'machine', name: 'Test', url: 'https://host.example', password: 'test');
const _session = Session(id: 'ses_test', title: 'Test', directory: '/work');

void main() {
  group('Uncertain send recovery', () {
    testWidgets(
        'Should reconcile a failed response by message ID without sending again',
        (tester) async {
      final fixture = _Fixture()..accepted = true;
      await fixture.show(tester);
      await tester.enterText(find.byType(TextField), 'Review');
      await tester.tap(find.byTooltip('Enviar mensagem'));
      await tester.pumpAndSettle();
      expect(fixture.posts, 1);
      expect(fixture.messageID, startsWith('msg_'));
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
          isEmpty);
      expect(find.text('Envio sem confirmação'), findsNothing);
      expect(fixture.store.bookmark(_machine.id, _session.id)?.pendingPrompt,
          isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Should block retries while uncertain and preserve a newer draft after confirmation',
        (tester) async {
      final fixture = _Fixture();
      await fixture.show(tester);
      await tester.enterText(find.byType(TextField), 'Original');
      await tester.tap(find.byTooltip('Enviar mensagem'));
      await tester.pumpAndSettle();
      expect(find.text('Envio sem confirmação'), findsOneWidget);
      expect(
          tester
              .widget<IconButton>(find.byWidgetPredicate((widget) =>
                  widget is IconButton && widget.tooltip == 'Enviar mensagem'))
              .onPressed,
          isNull);
      await tester.enterText(find.byType(TextField), 'New draft');
      fixture.accepted = true;
      await tester.ensureVisible(find.text('Conferir recebimento'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Conferir recebimento'));
      await tester.pumpAndSettle();
      expect(fixture.posts, 1);
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'New draft');
      expect(find.text('Envio sem confirmação'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Should restore uncertainty and require explicit acknowledgement to release sending',
        (tester) async {
      final fixture = _Fixture();
      await fixture.show(tester, restore: true);
      expect(find.text('Envio sem confirmação'), findsOneWidget);
      await tester.ensureVisible(find.text('Revisar e liberar novo envio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revisar e liberar novo envio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('Envio sem confirmação'), findsOneWidget);
      await tester.tap(find.text('Revisar e liberar novo envio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Já conferi, liberar'));
      await tester.pumpAndSettle();
      expect(find.text('Envio sem confirmação'), findsNothing);
      expect(fixture.posts, 0);
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'Original');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

class _Fixture {
  final store = AppStore();
  String messageID = '';
  bool accepted = false;
  int posts = 0;

  Future<void> show(WidgetTester tester, {bool restore = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    await store.load();
    if (restore) {
      final attempt = PromptAttempt.create('Original');
      messageID = attempt.id;
      await store.remember(_machine, _session,
          draft: 'Original', pendingPrompt: attempt);
    }
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = OpenCodeApi(_machine, client: MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/prompt')) {
        posts++;
        messageID = object(jsonDecode(request.body))['id'] as String;
        return http.Response('{}', 503);
      }
      if (messageID.isNotEmpty && path.endsWith('/message/$messageID')) {
        return accepted
            ? http.Response(
                jsonEncode({
                  'data': {'id': messageID, 'type': 'user'}
                }),
                200)
            : http.Response('{}', 404);
      }
      if (path == '/api/session/ses_test') {
        return http.Response(jsonEncode({'data': _session.toJson()}), 200);
      }
      if (path == '/api/session/active') {
        return http.Response(jsonEncode({'data': {}}), 200);
      }
      return http.Response(jsonEncode({'data': [], 'cursor': {}}), 200);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
            store: store,
            machine: _machine,
            session: _session,
            apiOverride: api)));
    await tester.pumpAndSettle();
  }
}
