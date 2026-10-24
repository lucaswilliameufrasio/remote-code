import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:remote_dev/core/api.dart';
import 'package:remote_dev/core/models.dart';
import 'package:remote_dev/features/pairing.dart';
import 'package:remote_dev/core/store.dart';
import 'package:remote_dev/features/home.dart';

const _machine = Machine(
    id: 'test', name: 'Test', url: 'https://test.example.ts.net', password: '');

void main() {
  group('Pairing confirmation', () {
    testWidgets(
        'Should persist the received credential only after saving the machine',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = AppStore();
      await store.load();
      final api = _PairApi();
      api.result.complete('synthetic-session-token');
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                                builder: (_) => MachineEditor(
                                    store: store, apiFactory: (_) => api))),
                        child: const Text('Add machine')),
                  ))));
      await tester.tap(find.text('Add machine'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'Test machine');
      await tester.enterText(find.byType(TextFormField).at(1), _machine.url);
      await tester
          .ensureVisible(find.text('Usar código temporário de pareamento'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Usar código temporário de pareamento'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'synthetic_code');
      await tester.ensureVisible(find.text('Confirmar destino e parear'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmar destino e parear'));
      await tester.pumpAndSettle();
      expect(store.machines, isEmpty);
      await tester.tap(find.text('Salvar máquina'));
      await tester.pumpAndSettle();
      expect(store.machines.single.password, 'synthetic-session-token');
      expect(store.machines.single.url, _machine.url);
    });
    testWidgets(
        'Should show the host and wait for explicit confirmation before redeeming',
        (tester) async {
      final api = _PairApi();
      await tester.pumpWidget(MaterialApp(
          home: PairingScreen(machine: _machine, apiFactory: (_) => api)));
      expect(find.text(_machine.url), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'synthetic_code');
      await tester.pump();
      expect(api.calls, 0);
      expect(
          tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
      await tester.tap(find.text('Confirmar destino e parear'));
      await tester.pump();
      expect(api.calls, 1);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      api.result.completeError(const ApiException(401, 'Expired code'));
      await tester.pumpAndSettle();
      expect(find.text('Expired code'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
          isEmpty);
    });

    testWidgets(
        'Should allow leaving during pairing without touching a disposed controller',
        (tester) async {
      final api = _PairApi();
      await tester.pumpWidget(MaterialApp(
          home: PairingScreen(machine: _machine, apiFactory: (_) => api)));
      await tester.tap(find.text('Confirmar destino e parear'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      api.result.complete('synthetic-session-token');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}

class _PairApi extends OpenCodeApi {
  final result = Completer<String>();
  int calls = 0;
  _PairApi() : super(_machine);
  @override
  Future<String> redeemPairingCode(String code) {
    calls++;
    return result.future;
  }
}
