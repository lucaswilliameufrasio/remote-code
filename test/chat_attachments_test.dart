import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/attachments.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/attachment_picker.dart';
import 'package:remote_dev/features/chat.dart';

void main() {
  testWidgets('Should review and remove an attachment without sending it',
      (tester) async {
    final requests = <http.Request>[];
    await _showChat(tester, requests, viewport: const Size(360, 800));
    await tester.tap(find.text('Anexar arquivo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('notes.txt'), findsOneWidget);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
    await tester.tap(find.byTooltip('Remover notes.txt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('notes.txt'), findsNothing);
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pumpAndSettle();
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Should send attachment-only messages and clear files only on success',
      (tester) async {
    final requests = <http.Request>[];
    await _showChat(tester, requests);
    await tester.tap(find.text('Anexar arquivo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pumpAndSettle();
    final prompts = requests
        .where((request) => request.url.path.endsWith('/prompt'))
        .toList();
    expect(prompts, hasLength(1));
    final payload = object(jsonDecode(prompts.single.body));
    expect(payload['text'], '');
    expect(objects(payload['files']).single, {
      'name': 'notes.txt',
      'uri': 'data:text/plain;base64,aGVsbG8=',
    });
    expect(find.textContaining('notes.txt'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Should retain the text and files after an uncertain send failure',
      (tester) async {
    final requests = <http.Request>[];
    await _showChat(tester, requests, promptStatus: 503);
    await tester.enterText(find.byType(TextField), 'Review this');
    await tester.tap(find.text('Anexar arquivo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pumpAndSettle();
    expect(find.textContaining('notes.txt'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'Review this');
    expect(requests.where((request) => request.url.path.endsWith('/prompt')),
        hasLength(1));
    expect(
        find.textContaining('O envio pode ter sido recebido'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should block PDF input when the model does not support PDF',
      (tester) async {
    final requests = <http.Request>[];
    await _showChat(tester, requests, pdf: true, modalities: ['text']);
    await tester.tap(find.text('Anexar arquivo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pumpAndSettle();
    expect(find.textContaining('notes.pdf'), findsOneWidget);
    expect(find.textContaining('não informa suporte a PDF'), findsOneWidget);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should send a compatible PDF through the busy-session queue',
      (tester) async {
    final requests = <http.Request>[];
    await _showChat(tester, requests,
        pdf: true, modalities: ['text', 'pdf'], busy: true);
    await tester.tap(find.text('Anexar arquivo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Enfileirar mensagem'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final prompt =
        requests.singleWhere((request) => request.url.path.endsWith('/prompt'));
    final payload = object(jsonDecode(prompt.body));
    expect(payload['delivery'], 'queue');
    expect(objects(payload['files']).single['name'], 'notes.pdf');
    final modelRequest = requests
        .singleWhere((request) => request.url.path == '/api/model/default');
    expect(
        modelRequest.url.queryParameters['location[directory]'], '/work/test');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Should treat native picker cancellation as no draft change',
      (tester) async {
    final requests = <http.Request>[];
    await _showChat(tester, requests, cancelled: true);
    await tester.enterText(find.byType(TextField), 'Keep my draft');
    await tester.tap(find.text('Anexar arquivo'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'Keep my draft');
    expect(find.textContaining('notes.txt'), findsNothing);
    expect(requests.where((request) => request.method == 'POST'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Picker implements AttachmentPicker {
  final PromptAttachment? attachment;
  _Picker(this.attachment);
  @override
  Future<PromptAttachment?> pick() async => attachment;
}

Future<void> _showChat(
  WidgetTester tester,
  List<http.Request> requests, {
  bool pdf = false,
  bool busy = false,
  bool cancelled = false,
  int promptStatus = 200,
  List<String> modalities = const ['text'],
  Size viewport = const Size(800, 1000),
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final store = AppStore();
  await store.load();
  await tester.binding.setSurfaceSize(viewport);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  const machine = Machine(
      id: 'test',
      name: 'Test',
      url: 'https://test.example.ts.net',
      password: 'test-password');
  const session =
      Session(id: 'ses_test', title: 'Test', directory: '/work/test');
  final file = PromptAttachment.fromBytes(pdf ? 'notes.pdf' : 'notes.txt',
      Uint8List.fromList(utf8.encode(pdf ? '%PDF-1.7' : 'hello')));
  await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
    store: store,
    machine: machine,
    session: session,
    attachmentPicker: _Picker(cancelled ? null : file),
    apiOverride: OpenCodeApi(machine, client: MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path.endsWith('/prompt')) {
        return http.Response(
            jsonEncode({
              'data': {
                'id': object(jsonDecode(request.body))['id'],
                'type': 'user',
              }
            }),
            promptStatus);
      }
      if (path == '/api/session/ses_test') {
        return http.Response(
            jsonEncode({
              'data': {
                'id': session.id,
                'title': session.title,
                'location': {'directory': session.directory},
              }
            }),
            200);
      }
      if (path == '/api/session/active') {
        return http.Response(
            jsonEncode({
              'data': busy
                  ? {
                      session.id: {'type': 'running'}
                    }
                  : {}
            }),
            200);
      }
      if (path == '/api/model/default') {
        return http.Response(
            jsonEncode({
              'data': {
                'id': 'default-model',
                'providerID': 'mock',
                'capabilities': {'input': modalities},
              }
            }),
            200);
      }
      return http.Response(jsonEncode({'data': [], 'cursor': {}}), 200);
    })),
  )));
  if (busy) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  } else {
    await tester.pumpAndSettle();
  }
}
