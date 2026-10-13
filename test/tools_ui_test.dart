import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/features/tools.dart';

const machine = Machine(
  id: 'desktop',
  name: 'Desktop',
  url: 'https://desktop.example.ts.net',
  password: 'secret',
);

const session = Session(
  id: 'ses_one',
  title: 'One',
  directory: '/work/a',
);

void main() {
  testWidgets('Should show MCP states and activate a registered skill',
      (tester) async {
    final requests = <http.Request>[];
    final api = OpenCodeApi(
      machine,
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/mcp') {
          return http.Response(
            jsonEncode({
              'location': {'directory': '/work/a'},
              'data': [
                {
                  'name': 'docs',
                  'status': {'status': 'connected'},
                },
                {
                  'name': 'tracker',
                  'status': {'status': 'disabled'},
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/skill') {
          return http.Response(
            jsonEncode({
              'location': {'directory': '/work/a'},
              'data': [
                {
                  'name': 'review',
                  'description': 'Review a proposed change',
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/session/active') {
          return http.Response(
            jsonEncode({
              'data': {
                'ses_one': {'type': 'idle'},
              },
            }),
            200,
          );
        }
        return http.Response('', 204);
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SessionToolsScreen(machine: machine, session: session, api: api),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('docs'), findsOneWidget);
    expect(find.text('Conectado'), findsOneWidget);
    expect(find.text('tracker'), findsOneWidget);
    expect(find.text('Desativado'), findsOneWidget);

    await tester.tap(find.byTooltip('Conectar tracker'));
    await tester.pumpAndSettle();

    expect(
      requests.any((request) =>
          request.method == 'POST' &&
          request.url.path == '/api/mcp/tracker/connect'),
      isTrue,
    );

    await tester.tap(find.text('Skills'));
    await tester.pumpAndSettle();
    expect(find.text('review'), findsOneWidget);
    await tester.tap(find.text('review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ativar e continuar'));
    await tester.pumpAndSettle();

    final skillRequest = requests.last;
    expect(skillRequest.method, 'POST');
    expect(skillRequest.url.path, '/api/session/ses_one/skill');
    expect(jsonDecode(skillRequest.body), {'skill': 'review', 'resume': true});

    api.close();
  });
}
