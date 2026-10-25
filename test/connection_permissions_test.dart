import 'dart:async';
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

void main() {
  group('Connection and permission clarity', () {
    testWidgets(
        'Should distinguish denied access from a generic unstable connection',
        (tester) async {
      await _show(tester, sessionStatus: 401);
      expect(find.text('Acesso negado'), findsOneWidget);
      expect(
          find.textContaining(
              'Confira as credenciais e as permissões da máquina'),
          findsOneWidget);
      expect(find.textContaining('atualizado'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Should show the last successful session refresh',
        (tester) async {
      await _show(tester);
      expect(find.textContaining('atualizado'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Should announce an observed running to idle transition only once',
        (tester) async {
      var running = true;
      await _show(tester, active: () => running);
      expect(find.textContaining('O agente deixou de executar'), findsNothing);
      running = false;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('O agente deixou de executar'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.textContaining('O agente deixou de executar'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Should display persistent patterns and allow cancelling without granting',
        (tester) async {
      var replies = 0;
      await _show(tester, permission: true, reply: (_) async {
        replies++;
        return http.Response('{}', 200);
      });
      await tester.ensureVisible(find.text('Sempre permitir'));
      expect(find.textContaining('Detectada neste celular'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sempre permitir'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Padrões persistentes'), findsOneWidget);
      expect(find.textContaining('git *'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(replies, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Should keep pending approvals scrollable with the keyboard open',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      var replies = 0;
      await _show(tester,
          permission: true,
          active: () => true,
          reply: (_) async {
            replies++;
            return http.Response('{}', 200);
          });
      await tester.binding.setSurfaceSize(const Size(440, 850));
      tester.view.viewInsets = const FakeViewPadding(bottom: 350);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Negar'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Negar'));
      await tester.pump();
      expect(replies, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Should announce a newly observed permission without its private details',
        (tester) async {
      var pending = false;
      await _show(tester, pendingPermission: () => pending);
      pending = true;
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.textContaining('O agente precisa da sua atenção'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('O agente precisa da sua atenção'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Should disable permission actions while a response is in flight',
        (tester) async {
      var replies = 0;
      final pending = Completer<http.Response>();
      await _show(tester, permission: true, reply: (_) {
        replies++;
        return pending.future;
      });
      await tester.ensureVisible(find.text('Uma vez'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uma vez'));
      await tester.pump();
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Uma vez'))
              .onPressed,
          isNull);
      expect(replies, 1);
      pending.complete(http.Response('{}', 200));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'Should refresh a permission resolved elsewhere without retrying the grant',
        (tester) async {
      var replies = 0;
      await _show(tester, permission: true, reply: (_) async {
        replies++;
        return http.Response('{}', 404);
      });
      await tester.ensureVisible(find.text('Uma vez'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uma vez'));
      await tester.pumpAndSettle();
      expect(find.textContaining('já foi resolvida'), findsOneWidget);
      expect(replies, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

Future<void> _show(WidgetTester tester,
    {int sessionStatus = 200,
    bool permission = false,
    bool Function()? active,
    bool Function()? pendingPermission,
    Future<http.Response> Function(http.Request)? reply}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final store = AppStore();
  await store.load();
  await tester.binding.setSurfaceSize(const Size(800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  const machine = Machine(
      id: 'test',
      name: 'Test',
      url: 'https://test.example.ts.net',
      password: 'test-password');
  const session =
      Session(id: 'ses_test', title: 'Test', directory: '/work/project');
  await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
          store: store,
          machine: machine,
          session: session,
          apiOverride: OpenCodeApi(machine, client: MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/reply') && reply != null) {
              return reply(request);
            }
            if (path == '/api/session/ses_test') {
              return http.Response(
                  jsonEncode({
                    'data': {
                      'id': session.id,
                      'title': session.title,
                      'location': {'directory': session.directory}
                    }
                  }),
                  sessionStatus);
            }
            if (path == '/api/session/active') {
              return http.Response(
                  jsonEncode({
                    'data': {
                      if (active?.call() == true)
                        session.id: {'type': 'running'},
                    }
                  }),
                  200);
            }
            if (path.endsWith('/permission') &&
                (permission || pendingPermission?.call() == true)) {
              return http.Response(
                  jsonEncode({
                    'data': [
                      {
                        'id': 'perm_test',
                        'sessionID': session.id,
                        'action': 'shell',
                        'resources': ['git status'],
                        'save': ['git *'],
                        'message': 'Review repository state',
                      }
                    ]
                  }),
                  200);
            }
            return http.Response(jsonEncode({'data': [], 'cursor': {}}), 200);
          })))));
  if (active != null) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  } else {
    await tester.pumpAndSettle();
  }
}
