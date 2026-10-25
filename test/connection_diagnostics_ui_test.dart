import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/connection_diagnostics.dart';
import 'package:remote_dev/features/home.dart';

void main() {
  const machine = Machine(
      id: 'private-id',
      name: 'private-name',
      url: 'https://private-host.example',
      password: 'private-password');

  setUp(() {
    PackageInfo.setMockInitialValues(
        appName: 'CodeRelay',
        packageName: 'example',
        version: '0.1.0',
        buildNumber: '1',
        buildSignature: '');
  });

  testWidgets(
      'Should open diagnostics from the editor without saving credentials',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(MaterialApp(
        home: MachineEditor(
      store: store,
      machine: machine,
      apiFactory: (value) => OpenCodeApi(value,
          client: MockClient((_) async => http.Response('{}', 401))),
    )));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Diagnóstico de conexão'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Diagnóstico de conexão'));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionDiagnosticsScreen), findsOneWidget);
    await tester.tap(find.text('Executar diagnóstico'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Autenticação recusada'), findsWidgets);
    expect(store.machines, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(MachineEditor), findsOneWidget);
    expect(store.machines, isEmpty);
  });

  testWidgets(
      'Should run only on demand and copy a report without machine data',
      (tester) async {
    var requests = 0;
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        home: ConnectionDiagnosticsScreen(
      machine: machine,
      apiFactory: (value) =>
          OpenCodeApi(value, client: MockClient((request) async {
        requests++;
        return http.Response('private-password', 401);
      })),
    )));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('App: 0.1.0+1'), findsOneWidget);
    await tester.tap(find.text('Executar diagnóstico'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.textContaining('Autenticação recusada'), findsWidgets);
    await tester.ensureVisible(find.text('Copiar relatório seguro'));
    await tester.tap(find.text('Copiar relatório seguro'));
    await tester.pumpAndSettle();
    expect(copied, contains('HTTP: 401'));
    expect(copied, isNot(contains('private-')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Should prevent overlapping runs and tolerate leaving during a request',
      (tester) async {
    final response = Completer<http.Response>();
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
        home: ConnectionDiagnosticsScreen(
      machine: machine,
      apiFactory: (value) => OpenCodeApi(value, client: MockClient((_) {
        requests++;
        return response.future;
      })),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Executar diagnóstico'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    response.complete(http.Response('{}', 503));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
